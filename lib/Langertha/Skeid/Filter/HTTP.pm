package Langertha::Skeid::Filter::HTTP;
our $VERSION = '0.006';
# ABSTRACT: The shipped filter: the filter context POSTed to a service, fail-closed
use Moo;
use Mojo::Promise;
use Mojo::UserAgent;
use namespace::clean;

=head1 SYNOPSIS

  # skeid.yaml
  filter:
    url: http://pii-filter.internal:8080/filter
    token_env: SKEID_FILTER_TOKEN      # the variable that holds the token, never the token
    timeout_ms: 2000
    when: [cloud]                      # nodes with one of these tags are filtered; none: all
    organization: acme
    pass_headers: [x-tenant]           # client headers the filter is told about

=head1 DESCRIPTION

What L<Langertha::Skeid/filter_request_p> uses when the config has a C<filter:> section (ADR
0035): it POSTs the filter context as JSON to L</url> and resolves with the decoded answer. The
call is non-blocking (L<Mojo::UserAgent>, ADR 0005) and bounded by L</timeout_ms>.

It fails closed. A status other than 200, an answer that is not a JSON object, a timeout, a
connection that fails, and a L</token_env> that names an unset variable all reject the promise
with a reason of a few words -- never the body, which carries the request's texts. The proxy
refuses the request then.

=attr url

The filter service's URL. Required.

=attr token_env

The name of the environment variable that holds the bearer token sent as C<Authorization>. The
token itself is read at each call and never kept in the config or written to a log (ADR 0003).
Without it no C<Authorization> is sent.

=attr timeout_ms

How long a call may take, connect included; default 5000.

=cut

has url        => (is => 'ro', required => 1);
has token_env  => (is => 'ro');
has timeout_ms => (is => 'ro', default => sub { 5000 });

has ua => (is => 'lazy');

sub _build_ua {
  my ($self) = @_;
  my $seconds = $self->timeout_ms / 1000;
  return Mojo::UserAgent->new(
    connect_timeout    => $seconds,
    request_timeout    => $seconds,
    inactivity_timeout => $seconds,
    max_redirects      => 0,
  );
}

=method request_p

  $filter->request_p($ctx)->then(sub { my ($answer) = @_; ... });

The filter's answer to C<$ctx> as a promise: the decoded JSON object of a 200, or a rejection
with a short reason.

=cut

sub request_p {
  my ($self, $ctx) = @_;
  my %headers = ('Content-Type' => 'application/json');
  if (defined(my $env = $self->token_env)) {
    my $token = $ENV{$env};
    return Mojo::Promise->reject("token_env '$env' is not set")
      unless defined($token) && length($token);
    $headers{Authorization} = 'Bearer ' . $token;
  }
  return $self->ua->post_p($self->url, \%headers, json => $ctx)->then(sub {
    my ($tx) = @_;
    my $res = $tx->res;
    if (my $err = $tx->error) {
      return Mojo::Promise->reject(defined($err->{code}) ? "status $err->{code}" : 'connection failed');
    }
    return Mojo::Promise->reject('status ' . ($res->code // 'none')) unless ($res->code // 0) == 200;
    my $answer = eval { $res->json };
    return Mojo::Promise->reject('the answer is not a JSON object') unless ref($answer) eq 'HASH';
    return $answer;
  }, sub {
    my ($err) = @_;
    # Mojo::UserAgent's own words for a timeout or a refused connection; they quote no body.
    my $reason = "$err";
    $reason =~ s/\s+at \S+ line \d+.*//s;
    return Mojo::Promise->reject($reason =~ /timeout/i ? 'timeout' : 'connection failed');
  });
}

1;
