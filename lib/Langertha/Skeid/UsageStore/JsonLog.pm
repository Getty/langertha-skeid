package Langertha::Skeid::UsageStore::JsonLog;
our $VERSION = '0.003';
# ABSTRACT: Append-only JSON usage store — one file per event, or one line per event
use Moo;
use strict;
use warnings;
use POSIX qw(strftime);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use JSON::MaybeXS qw(encode_json decode_json);
use Langertha::Skeid::UsageStore;

=head1 DESCRIPTION

The recommended usage store. Writing an event is an append, so it cannot block the event loop
on a database round-trip the way the DBI backends can, and an append-only file is the easiest
thing to reconcile after an incident.

Reporting reads and aggregates the whole log in memory. That is fine for the volumes this is
meant for and deliberately not optimised — if a deployment outgrows it, the answer is a real
database, not an index on a directory of JSON files.

=attr path

Directory (C<mode> C<dir>) or file (C<mode> C<file>) the events are written to.

=attr mode

C<dir> writes one C<< <id>.json >> per event, which never needs a lock. C<file> appends one
JSON line per event under an exclusive C<flock>.

=cut

has path => (is => 'ro', required => 1);
has mode => (is => 'ro', default => sub { 'dir' });

=method backend

Returns C<jsonlog>.

=cut

sub backend { 'jsonlog' }

=method prepare

Creates the target directory (or the file's parent directory). Called when the store is
configured, not when an event is written.

=cut

sub prepare {
  my ($self) = @_;
  my $path = $self->path;
  if ($self->mode eq 'dir') {
    make_path($path) unless -d $path;
  } else {
    my $dir = dirname($path);
    make_path($dir) if length($dir) && $dir ne '.' && !-d $dir;
  }
  return 1;
}

=method disconnect

No-op — nothing is held open between writes.

=cut

sub disconnect { return }

sub _event_id {
  my $ts = strftime('%Y%m%d-%H%M%S', gmtime());
  my $rand = sprintf('%06d', int(rand(1_000_000)));
  return "${ts}-${rand}";
}

=method store

  my $res = $store->store($event);

Writes one event and returns C<< { ok => 1, id => $id } >>, or C<< { ok => 0, error => … } >>.
A write failure is reported, never thrown: losing a usage event must not also fail the request
that was already served.

=cut

sub store {
  my ($self, $event) = @_;
  my $id = _event_id();
  my $json = encode_json({ %$event, id => $id });

  if ($self->mode eq 'dir') {
    my $file = File::Spec->catfile($self->path, "${id}.json");
    open my $fh, '>', $file or return { ok => 0, error => "Cannot write $file: $!" };
    print $fh $json, "\n";
    close $fh;
  } else {
    my $path = $self->path;
    open my $fh, '>>', $path or return { ok => 0, error => "Cannot append $path: $!" };
    flock($fh, 2); # LOCK_EX
    print $fh $json, "\n";
    close $fh;
  }

  return { ok => 1, id => $id };
}

=method report

  my $report = $store->report(\%filters);

Reads every event, applies the C<since> / C<api_key_id> / C<model> filters, and aggregates
totals plus per-key and per-model breakdowns. C<recent> holds the newest C<limit> events.

=cut

sub report {
  my ($self, $filters) = @_;
  $filters ||= {};
  my $num = \&Langertha::Skeid::UsageStore::num;

  my @events;
  if ($self->mode eq 'dir') {
    my @files = sort glob(File::Spec->catfile($self->path, '*.json'));
    for my $file (@files) {
      my $text = eval { Langertha::Skeid::UsageStore::read_text_file($file) };
      next unless defined $text;
      my $ev = eval { decode_json($text) };
      push @events, $ev if ref($ev) eq 'HASH';
    }
  } else {
    if (open my $fh, '<', $self->path) {
      while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my $ev = eval { decode_json($line) };
        push @events, $ev if ref($ev) eq 'HASH';
      }
      close $fh;
    }
  }

  if (defined $filters->{since} && length $filters->{since}) {
    @events = grep { ($_->{created_at} // '') ge $filters->{since} } @events;
  }
  if (defined $filters->{api_key_id} && length $filters->{api_key_id}) {
    @events = grep { ($_->{api_key_id} // '') eq $filters->{api_key_id} } @events;
  }
  if (defined $filters->{model} && length $filters->{model}) {
    @events = grep { ($_->{model} // '') eq $filters->{model} } @events;
  }

  my %totals = (requests => 0, input_tokens => 0, output_tokens => 0, total_tokens => 0, tool_calls => 0, total_cost_usd => 0);
  my (%by_key, %by_model);
  for my $ev (@events) {
    $totals{requests}++;
    $totals{input_tokens}  += $num->($ev->{input_tokens});
    $totals{output_tokens} += $num->($ev->{output_tokens});
    $totals{total_tokens}  += $num->($ev->{total_tokens});
    $totals{tool_calls}    += $num->($ev->{tool_calls});
    $totals{total_cost_usd} += $num->($ev->{cost_total_usd});

    my $kid = $ev->{api_key_id} // '';
    $by_key{$kid}{requests}++;
    $by_key{$kid}{total_tokens}   += $num->($ev->{total_tokens});
    $by_key{$kid}{total_cost_usd} += $num->($ev->{cost_total_usd});

    my $mid = $ev->{model} // '';
    $by_model{$mid}{requests}++;
    $by_model{$mid}{total_tokens}   += $num->($ev->{total_tokens});
    $by_model{$mid}{total_cost_usd} += $num->($ev->{cost_total_usd});
  }

  my $limit = $filters->{limit} // 20;
  my @recent = reverse @events;
  @recent = @recent[0 .. $limit - 1] if @recent > $limit;

  return {
    ok      => 1,
    enabled => 1,
    backend => 'jsonlog',
    since   => ($filters->{since} // ''),
    totals  => \%totals,
    by_key  => [ map {
      +{ api_key_id => $_, requests => $by_key{$_}{requests}, total_tokens => $by_key{$_}{total_tokens}, total_cost_usd => $by_key{$_}{total_cost_usd} }
    } sort { ($by_key{$b}{total_cost_usd} || 0) <=> ($by_key{$a}{total_cost_usd} || 0) } keys %by_key ],
    by_model => [ map {
      +{ model => $_, requests => $by_model{$_}{requests}, total_tokens => $by_model{$_}{total_tokens}, total_cost_usd => $by_model{$_}{total_cost_usd} }
    } sort { ($by_model{$b}{total_cost_usd} || 0) <=> ($by_model{$a}{total_cost_usd} || 0) } keys %by_model ],
    recent  => [ map {
      +{
        id => ($_->{id} // ''), created_at => ($_->{created_at} // ''), api_format => ($_->{api_format} // ''),
        endpoint => ($_->{endpoint} // ''), api_key_id => ($_->{api_key_id} // ''), model => ($_->{model} // ''),
        requested_model => ($_->{requested_model} // $_->{model} // ''),
        node_id => ($_->{node_id} // ''), status_code => $num->($_->{status_code}), ok => ($_->{ok} ? 1 : 0),
        input_tokens => $num->($_->{input_tokens}), output_tokens => $num->($_->{output_tokens}),
        total_tokens => $num->($_->{total_tokens}), tool_calls => $num->($_->{tool_calls}),
        cost_total_usd => $num->($_->{cost_total_usd}),
      }
    } @recent ],
  };
}

1;
