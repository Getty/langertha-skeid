package Test::Skeid::Filter;
# ABSTRACT: A deployment's filter, for the tests: known words become placeholders

# What ADR 0035 means by a filter: a Langertha::Skeid subclass that overrides filter_request_p,
# here with a word list instead of a model. Each word of `words` found in a text is replaced by
# its placeholder, and the map says which span of which text it stood for. `decision` forces
# another answer (local, refuse, or a coderef returning the whole answer); `hold` keeps the
# promise for the test to settle. t/104-filter-seam.t drives it.

use Moo;
use Mojo::Promise;
use namespace::clean;
extends 'Langertha::Skeid';

# [ [word, placeholder], ... ], replaced in this order.
has words => (is => 'rw', default => sub { [
  ['Max Mustermann',     "\x{27E6}PERSON_1\x{27E7}"],
  ['max@example.org',    "\x{27E6}EMAIL_1\x{27E7}"],
  ['Erika "E" M\\uller', "\x{27E6}PERSON_2\x{27E7}"],
] });

has decision => (is => 'rw');
has hold     => (is => 'rw', default => sub { 0 });
has held     => (is => 'ro', default => sub { [] });
has contexts => (is => 'ro', default => sub { [] });
has usage    => (is => 'rw', default => sub { { pii_found => 0 } });

sub filter_request_p {
  my ($self, $ctx) = @_;
  push @{$self->contexts}, $ctx;
  my $decision = $self->decision;
  my $answer = ref($decision) eq 'CODE' ? $decision->($ctx)
    : defined($decision) ? { decision => $decision, usage => { %{$self->usage} } }
    : $self->_replace($ctx);
  if ($self->hold) {
    my $p = Mojo::Promise->new;
    push @{$self->held}, [$p, $answer];
    return $p;
  }
  return Mojo::Promise->resolve($answer);
}

sub _replace {
  my ($self, $ctx) = @_;
  my (@texts, @map);
  my $found = 0;
  for my $text (@{$ctx->{texts}}) {
    my $out = $text->{text};
    my $changed = 0;
    for my $pair (@{$self->words}) {
      my ($word, $placeholder) = @$pair;
      my $at = index($text->{text}, $word);
      next if $at < 0;
      push @map, { id => $text->{id}, text => $word, start => $at, end => $at + length($word),
        placeholder => $placeholder };
      $out =~ s/\Q$word\E/$placeholder/g;
      $changed = 1;
      $found++;
    }
    push @texts, { id => $text->{id}, text => $out } if $changed;
  }
  return {
    decision => (@texts ? 'replace' : 'pass'),
    texts    => \@texts,
    map      => \@map,
    headers  => { 'X-Skeid-Filter' => 'done' },
    usage    => { %{$self->usage}, pii_found => $found },
  };
}

1;
