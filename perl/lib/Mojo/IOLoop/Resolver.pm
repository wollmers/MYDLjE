package Mojo::IOLoop::Resolver;
use Mojo::Base -base;

use IO::File;
use List::Util 'first';
use Scalar::Util 'weaken';
use Socket;

use constant DEBUG => $ENV{MOJO_RESOLVER_DEBUG} || 0;

# IPv6 DNS support requires "AF_INET6" and "inet_pton"
use constant IPV6 => defined &Socket::AF_INET6 && defined &Socket::inet_pton;

has ioloop => sub {
  require Mojo::IOLoop;
  Mojo::IOLoop->singleton;
};
has timeout => 3;

# IPv4 regex (RFC 3986)
my $DEC_OCTET_RE = qr/(?:[0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])/;
our $IPV4_RE =
  qr/^$DEC_OCTET_RE\.$DEC_OCTET_RE\.$DEC_OCTET_RE\.$DEC_OCTET_RE$/;

# IPv6 regex (RFC 3986)
my $H16_RE  = qr/[0-9A-Fa-f]{1,4}/;
my $LS32_RE = qr/(?:$H16_RE:$H16_RE|$IPV4_RE)/;
our $IPV6_RE = qr/(?:
                                           (?: $H16_RE : ){6} $LS32_RE
  |                                     :: (?: $H16_RE : ){5} $LS32_RE
  | (?:                      $H16_RE )? :: (?: $H16_RE : ){4} $LS32_RE
  | (?: (?: $H16_RE : ){0,1} $H16_RE )? :: (?: $H16_RE : ){3} $LS32_RE
  | (?: (?: $H16_RE : ){0,2} $H16_RE )? :: (?: $H16_RE : ){2} $LS32_RE
  | (?: (?: $H16_RE : ){0,3} $H16_RE )? ::     $H16_RE :      $LS32_RE
  | (?: (?: $H16_RE : ){0,4} $H16_RE )? ::                    $LS32_RE
  | (?: (?: $H16_RE : ){0,5} $H16_RE )? ::                    $H16_RE
  | (?: (?: $H16_RE : ){0,6} $H16_RE )? ::
)/x;

# DNS server (default to Google Public DNS)
my $SERVERS = ['8.8.8.8', '8.8.4.4'];

# Try to detect DNS server
if (-r '/etc/resolv.conf') {
  my $file = IO::File->new('< /etc/resolv.conf');
  my @servers;
  for my $line (<$file>) {

    # New DNS server
    if ($line =~ /^nameserver\s+(\S+)$/) {
      push @servers, $1;
      warn qq/DETECTED DNS SERVER ($1)\n/ if DEBUG;
    }
  }
  unshift @$SERVERS, @servers;
}

# User defined DNS server
unshift @$SERVERS, $ENV{MOJO_DNS_SERVER} if $ENV{MOJO_DNS_SERVER};

# Always start with first DNS server
my $CURRENT_SERVER = 0;

# DNS record types
my $DNS_TYPES = {
  '*'   => 0x00ff,
  A     => 0x0001,
  AAAA  => 0x001c,
  CNAME => 0x0005,
  MX    => 0x000f,
  NS    => 0x0002,
  PTR   => 0x000c,
  TXT   => 0x0010
};

# "localhost"
our $LOCALHOST = '127.0.0.1';

sub DESTROY { shift->_cleanup }

sub is_ipv4 {
  return 1 if $_[1] =~ $IPV4_RE;
  return;
}

sub is_ipv6 {
  return 1 if $_[1] =~ $IPV6_RE;
  return;
}

sub lookup {
  my ($self, $name, $cb) = @_;

  # "localhost"
  weaken $self;
  return $self->ioloop->timer(0 => sub { $self->$cb($LOCALHOST) })
    if $name eq 'localhost';

  # IPv4
  $self->resolve(
    $name, 'A',
    sub {
      my ($self, $records) = @_;

      # Success
      my $result = first { $_->[0] eq 'A' } @$records;
      return $self->$cb($result->[1]) if $result;

      # IPv6
      $self->resolve(
        $name, 'AAAA',
        sub {
          my ($self, $records) = @_;

          # Success
          my $result = first { $_->[0] eq 'AAAA' } @$records;
          return $self->$cb($result->[1]) if $result;

          # Nothing
          $self->$cb();
        }
      );
    }
  );
}

# "I can't believe it! Reading and writing actually paid off!"
sub resolve {
  my ($self, $name, $type, $cb) = @_;

  # No lookup required or record type not supported
  my $t      = $DNS_TYPES->{$type};
  my $v4     = $self->is_ipv4($name);
  my $v6     = IPV6 ? $self->is_ipv6($name) : 0;
  my $server = $self->servers;
  my $loop   = $self->ioloop;
  weaken $self;
  return $loop->timer(0 => sub { $self->$cb([]) })
    if !$server || !$t || ($t ne $DNS_TYPES->{PTR} && ($v4 || $v6));

  # Build request
  warn "RESOLVE $type $name ($server)\n" if DEBUG;
  my $tx;
  do { $tx = int rand 0x10000 } while ($self->{requests}->{$tx});

  # Header (one question with recursion)
  my $req = pack 'nnnnnn', $tx, 0x0100, 1, 0, 0, 0;

  # Reverse
  my @parts = split /\./, $name;
  if ($t eq $DNS_TYPES->{PTR}) {

    # IPv4
    if ($v4) { @parts = reverse 'arpa', 'in-addr', @parts }

    # IPv6
    elsif ($v6) {
      @parts = reverse 'arpa', 'ip6', split //, unpack 'H32',
        Socket::inet_pton(Socket::AF_INET6(), $name);
    }
  }

  # Query (Internet)
  for my $part (@parts) { $req .= pack 'C/a*', $part if defined $part }
  $req .= pack 'Cnn', 0, $t, 0x0001;

  # Send request
  $self->_bind($server);
  $self->{requests}->{$tx} = {
    cb    => $cb,
    timer => $loop->timer(
      $self->timeout => sub {
        my $loop = shift;
        warn "RESOLVE TIMEOUT ($server)\n" if DEBUG;
        $CURRENT_SERVER++;
        $self->_cleanup;
      }
    )
  };
  $loop->write($self->{id} => $req);
}

# "I wonder where Bart is, his dinner's getting all cold... and eaten."
sub servers {
  my $self = shift;

  # New servers
  if (@_) {
    @$SERVERS       = @_;
    $CURRENT_SERVER = 0;
  }

  # List all
  return @$SERVERS if wantarray;

  # Current server
  $CURRENT_SERVER = 0 unless $SERVERS->[$CURRENT_SERVER];
  return $SERVERS->[$CURRENT_SERVER];
}

sub _bind {
  my ($self, $server) = @_;

  # Reuse socket
  return if $self->{id};

  # New socket
  my $loop = $self->ioloop;
  weaken $self;
  $self->{id} = $loop->connect(
    address  => $server,
    port     => 53,
    on_close => sub { $self->_cleanup },
    on_error => sub {
      my $loop = shift;
      warn "RESOLVE FAILURE ($server)\n" if DEBUG;
      $CURRENT_SERVER++;
      $self->_cleanup;
    },
    on_read => sub {
      my ($loop, $id, $chunk) = @_;

      # Parse response
      my @packet = unpack 'nnnnnna*', $chunk;
      warn "ANSWERS $packet[3] ($server)\n" if DEBUG;
      return unless my $r = delete $self->{requests}->{$packet[0]};

      # Questions
      my $content = $packet[6];
      for (1 .. $packet[2]) {
        my $n;
        do { ($n, $content) = unpack 'C/aa*', $content } while ($n ne '');
        $content = (unpack 'nna*', $content)[2];
      }

      # Answers
      my @answers;
      for (1 .. $packet[3]) {

        # Parse
        (my ($t, $ttl, $a), $content) =
          (unpack 'nnnNn/aa*', $content)[1, 3, 4, 5];
        my @answer = _parse_answer($t, $a, $chunk, $content);

        # No answer
        next unless @answer;

        # Answer
        push @answers, [@answer, $ttl];
        warn "ANSWER $answer[0] $answer[1]\n" if DEBUG;
      }
      $loop->drop($r->{timer});
      $r->{cb}->($self, \@answers);
    },
    args => {Proto => 'udp', Type => SOCK_DGRAM}
  );
}

sub _cleanup {
  my $self = shift;
  return unless my $loop = $self->ioloop;
  $loop->drop(delete $self->{id}) if $self->{id};
  for my $tx (keys %{$self->{requests}}) {
    my $r = delete $self->{requests}->{$tx};
    $r->{cb}->($self, []);
  }
}

sub _parse_answer {
  my ($t, $a, $packet, $rest) = @_;

  # A
  if ($t eq $DNS_TYPES->{A}) { return A => join('.', unpack 'C4', $a) }

  # AAAA
  elsif ($t eq $DNS_TYPES->{AAAA}) {
    return AAAA => sprintf('%x:%x:%x:%x:%x:%x:%x:%x', unpack('n*', $a));
  }

  # TXT
  elsif ($t eq $DNS_TYPES->{TXT}) { return TXT => unpack('(C/a*)*', $a) }

  # Offset
  my $offset = length($packet) - length($rest) - length($a);

  # CNAME
  my $type;
  if ($t eq $DNS_TYPES->{CNAME}) { $type = 'CNAME' }

  # MX
  elsif ($t eq $DNS_TYPES->{MX}) {
    $type = 'MX';
    $offset += 2;
  }

  # NS
  elsif ($t eq $DNS_TYPES->{NS}) { $type = 'NS' }

  # PTR
  elsif ($t eq $DNS_TYPES->{PTR}) { $type = 'PTR' }

  # Domain name
  return $type => _parse_name($packet, $offset) if $type;

  # Not supported
  return;
}

sub _parse_name {
  my ($packet, $offset) = @_;

  # Elements
  my @elements;
  for (1 .. 128) {

    # Element length
    my $len = ord substr $packet, $offset++, 1;

    # Offset
    if ($len >= 0xc0) {
      $offset = (unpack 'n', substr $packet, ++$offset - 2, 2) & 0x3fff;
    }

    # Element
    elsif ($len) {
      push @elements, substr $packet, $offset, $len;
      $offset += $len;
    }

    # Zero length element (the end)
    else { return join '.', @elements }
  }

  return;
}

1;
__END__

=head1 NAME

Mojo::IOLoop::Resolver - IOLoop DNS Stub Resolver

=head1 SYNOPSIS

  use Mojo::IOLoop::Resolver;

=head1 DESCRIPTION

L<Mojo::IOLoop::Resolver> is a minimalistic async I/O DNS stub resolver used
by L<Mojo:IOLoop>.
Note that this module is EXPERIMENTAL and might change without warning!

=head1 ATTRIBUTES

L<Mojo::IOLoop::Resolver> implements the following attributes.

=head2 C<ioloop>

  my $ioloop = $resolver->ioloop;
  $resolver  = $resolver->ioloop(Mojo::IOLoop->new);

Loop object to use for I/O operations, defaults to a L<Mojo::IOLoop> object.

=head2 C<timeout>

  my $timeout = $resolver->timeout;
  $resolver   = $resolver->timeout(5);

Maximum time in seconds a C<DNS> lookup can take, defaults to C<3>.

=head1 METHODS

L<Mojo::IOLoop::Resolver> inherits all methods from L<Mojo::Base> and
implements the following new ones.

=head2 C<is_ipv4>

  my $is_ipv4 = $resolver->is_ipv4('127.0.0.1');

Check if value is a valid C<IPv4> address.

=head2 C<is_ipv6>

  my $is_ipv6 = $resolver->is_ipv6('::1');

Check if value is a valid C<IPv6> address.

=head2 C<lookup>

  $resolver->lookup('mojolicio.us' => sub {...});

Lookup C<IPv4> or C<IPv6> address for domain.

  $resolver->lookup('mojolicio.us' => sub {
    my ($loop, $address) = @_;
    print "Address: $address\n";
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->start;

=head2 C<resolve>

  $resolver->resolve('mojolicio.us', 'A', sub {...});

Resolve domain into C<A>, C<AAAA>, C<CNAME>, C<MX>, C<NS>, C<PTR> or C<TXT>
records, C<*> will query for all at once.
Since this is a "stub resolver" it depends on a recursive name server for DNS
resolution.

=head2 C<servers>

  my @all     = $resolver->servers;
  my $current = $resolver->servers;
  $resolver->servers('8.8.8.8', '8.8.4.4');

IP addresses of C<DNS> servers used for lookups, defaults to the value of
the C<MOJO_DNS_SERVER> environment variable, auto detection, C<8.8.8.8> or
C<8.8.4.4>.

=head1 DEBUGGING

You can set the C<MOJO_RESOLVER_DEBUG> environment variable to get some
advanced diagnostics information printed to C<STDERR>.

  MOJO_RESOLVER_DEBUG=1

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut