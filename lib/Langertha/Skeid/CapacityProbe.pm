package Langertha::Skeid::CapacityProbe;
our $VERSION = '0.003';
# ABSTRACT: Background probes that report what a node's real capacity is
use Moo;
use Carp qw(croak);
use Scalar::Util qw(blessed weaken);
use namespace::clean;

=head1 DESCRIPTION

C<inflight> counts what B<this> process sent to a node. That is exact for one Skeid in front of
one node, and wrong the moment anything else sends work there — a second frontend, a prefork
worker, a batch job, an engineer with C<curl>. Each counter then sees only its own share, every
instance believes the node is emptier than it is, and together they over-admit.

A probe reports what the node itself says instead. See ADR 0009 for why this rather than a
shared counter in Redis.

=head2 Writing one

Subclass this, implement L</poll>, and report through L<Langertha::Skeid/set_capacity_reading>.
Two rules that are not negotiable:

=over 4

=item * B<Never on the request path.> Polling is a timer. A probe that resolves during a
request has moved a network round-trip into the latency of a request that did not ask for it.

=item * B<Report nothing rather than something old.> If the source cannot be reached, call
C<forget_capacity>. Admission falls back to C<inflight>, which is merely imprecise; a stale
reading is confidently wrong.

=back

=cut

=attr skeid

The control plane to report to.

=cut

has skeid => (
  is       => 'ro',
  required => 1,
);

=attr node_id

Which node this probe describes.

=cut

has node_id => (
  is       => 'ro',
  required => 1,
);

=attr interval_ms

How often to poll (default 2000). The right value is a trade between staleness and load on the
node's metrics endpoint, and ADR 0009 leaves it open pending measurement — 2s is a starting
point, not a finding.

=cut

has interval_ms => (
  is      => 'rw',
  default => sub { 2000 },
);

=attr config

The node's C<capacity> block, verbatim.

=cut

has config => (
  is      => 'ro',
  default => sub { {} },
);

has _timer => (
  is      => 'rw',
  clearer => '_clear_timer',
);

=method poll

  $probe->poll;

What a subclass implements: read the source, then either C<set_capacity_reading> or
C<forget_capacity> on L</skeid>. Must not block.

=cut

sub poll {
  my ($self) = @_;
  croak ref($self) . " must implement poll()";
}

=method start

  $probe->start;

Begins polling on a timer, and polls once immediately so the first request does not have to
wait an interval for a reading. Safe to call twice.

=cut

sub start {
  my ($self) = @_;
  return $self->_timer if $self->_timer;
  require Mojo::IOLoop;

  my $every = ($self->interval_ms || 2000) / 1000;
  $every = 0.1 if $every < 0.1;

  # Weak, or the timer's closure keeps the probe (and the whole control plane) alive forever.
  my $weak = $self;
  weaken($weak);

  my $id = Mojo::IOLoop->recurring($every => sub {
    my $probe = $weak or return;
    # A probe that dies takes the timer's reactor with it otherwise, and one unreachable
    # metrics endpoint should not stop the proxy.
    eval { $probe->poll; 1 } or do {
      my $err = $@ || 'unknown error';
      $err =~ s/\s+\z//;
      warn "capacity probe for '" . $probe->node_id . "' failed: $err";
      $probe->skeid->forget_capacity($probe->node_id);
    };
  });
  $self->_timer($id);

  eval { $self->poll; 1 } or do { $self->skeid->forget_capacity($self->node_id) };
  return $id;
}

=method stop

Stops polling and drops the node's reading, so admission goes back to C<inflight> rather than
acting on whatever this probe last said.

=cut

sub stop {
  my ($self) = @_;
  if (my $id = $self->_timer) {
    require Mojo::IOLoop;
    eval { Mojo::IOLoop->remove($id) };
    $self->_clear_timer;
  }
  $self->skeid->forget_capacity($self->node_id);
  return 1;
}

=method for_node

  my $probe = Langertha::Skeid::CapacityProbe->for_node($skeid, $node);

Builds the probe a node's C<capacity> block asks for, or nothing when it asks for none.

  capacity:
    probe: prometheus              # or: inflight, custom
    url: http://gpu-1:8000/metrics
    interval_ms: 2000

C<inflight> (and an absent block) means no probe object at all — that is the default admission
path, not a probe that reports the same thing. C<ratelimit> is likewise not built here: it is
passive, read off responses the proxy already has, and needs nothing running.

C<custom> takes either a C<code> callback (given the probe, reports through the same methods)
or a C<class> to load, because Skeid is generic and the built-ins only cover the engines we
happen to know.

=cut

sub for_node {
  my ($class, $skeid, $node) = @_;
  return unless ref($node) eq 'HASH';
  my $cfg = $node->{capacity};
  return unless ref($cfg) eq 'HASH';

  my $kind = lc($cfg->{probe} // $cfg->{type} // 'inflight');
  return if $kind eq 'inflight' || $kind eq 'none' || $kind eq 'ratelimit';

  my %args = (
    skeid   => $skeid,
    node_id => $node->{id},
    config  => $cfg,
    (defined $cfg->{interval_ms} ? (interval_ms => 0 + $cfg->{interval_ms}) : ()),
  );

  if ($kind eq 'prometheus') {
    require Langertha::Skeid::CapacityProbe::Prometheus;
    return Langertha::Skeid::CapacityProbe::Prometheus->new(%args);
  }

  if ($kind eq 'custom') {
    if (ref($cfg->{code}) eq 'CODE') {
      require Langertha::Skeid::CapacityProbe::Custom;
      return Langertha::Skeid::CapacityProbe::Custom->new(%args, code => $cfg->{code});
    }
    my $custom_class = $cfg->{class} or croak "capacity probe 'custom' needs a code or class";
    # A class name out of a config file is loaded by name, so keep it looking like one.
    croak "invalid capacity probe class '$custom_class'"
      unless $custom_class =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;
    my $path = $custom_class . '.pm';
    $path =~ s{::}{/}g;
    require $path;
    return $custom_class->new(%args);
  }

  croak "unknown capacity probe '$kind'";
}

=method start_for_skeid

  my $probes = Langertha::Skeid::CapacityProbe->start_for_skeid($skeid);

Builds and starts a probe for every node that asks for one, and returns them by node id. The
caller holds them: a probe that goes out of scope stops polling.

=cut

sub start_for_skeid {
  my ($class, $skeid) = @_;
  my %probes;
  for my $node (@{$skeid->nodes}) {
    my $probe = eval { $class->for_node($skeid, $node) };
    if ($@) {
      my $err = $@; $err =~ s/\s+\z//;
      warn "capacity probe for '" . ($node->{id} // '?') . "' not started: $err";
      next;
    }
    next unless $probe;
    $probe->start;
    $probes{$node->{id}} = $probe;
  }
  return \%probes;
}

1;
