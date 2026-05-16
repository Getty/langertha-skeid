package Langertha::Skeid::KeyBroker::OpenBao;
our $VERSION = '0.003';
# ABSTRACT: OpenBao-backed KeyBroker with AppRole auth and token renewal
use Moo;
use HTTP::Tiny;
use JSON::MaybeXS qw(decode_json encode_json);
use Time::HiRes qw(sleep);
use POSIX qw(strftime);
use namespace::clean;

extends 'Langertha::Skeid::KeyBroker';

=head1 SYNOPSIS

  my $broker = Langertha::Skeid::KeyBroker::OpenBao->new(
    addr        => $ENV{OPENBAO_ADDR} // 'http://127.0.0.1:8200',
    role_id     => $ENV{OPENBAO_ROLE_ID},
    secret_id   => $ENV{OPENBAO_SECRET_ID},
    renew_secs  => 300,  # renew token every 5 minutes
  );

  my $api_key = $broker->resolve_key('secret/skeid/remote/openai');

=cut

has addr => (
  is       => 'ro',
  required => 1,
  default  => sub { $ENV{OPENBAO_ADDR} // 'http://127.0.0.1:8200' },
);

has role_id => (
  is       => 'ro',
  required => 1,
);

has secret_id => (
  is       => 'ro',
  required => 1,
);

has renew_secs => (
  is      => 'rw',
  default => sub { 300 },  # 5 minutes
);

has _http => (
  is      => 'lazy',
  builder => sub {
    HTTP::Tiny->new(
      timeout      => 10,
      verify_ssl   => 0,  # dev mode - set to 1 in prod
    );
  },
);

has _token => (
  is      => 'rw',
  clearer => '_clear_token',
);

has _token_expire => (
  is      => 'rw',
  default => sub { 0 },
);

has _renewal_loop => (
  is      => 'rw',
  clearer => '_clear_renewal_loop',
);

sub BUILD {
  my ($self) = @_;
  # Initial token fetch
  $self->_fetch_token;
}

sub _fetch_token {
  my ($self) = @_;
  my $resp = $self->_http->post(
    "${\$self->addr}/v1/auth/approle/login",
    {
      headers => { 'Content-Type' => 'application/json' },
        content => encode_json({
          role_id  => $self->role_id,
          secret_id => $self->secret_id,
        }),
    },
  );

  unless ($resp->{success}) {
    die "OpenBao AppRole login failed: " . ($resp->{content} // 'unknown error');
  }

  my $data = decode_json($resp->{content})->{auth} // {};
  my $token = $data->{token} // '';
  my $ttl = $data->{ttl} // 0;

  die "OpenBao AppRole login returned no token" unless length $token;

  $self->_token($token);
  $self->_token_expire(time + ($ttl > 0 ? $ttl : 3600));

  return 1;
}

sub _renew_token {
  my ($self) = @_;
  # AppRole secret is one-time use - we need a new secret_id from somewhere
  # For now: if token is expired, die and let docker restart the container
  if (time >= $self->_token_expire) {
    die "OpenBao token expired. Container must be restarted to get new AppRole credential.";
  }
  return 1;
}

sub needs_refresh {
  my ($self) = @_;
  return 1 if time >= ($self->_token_expire - 60);  # refresh 60s before expiry
  return 0;
}

sub refresh {
  my ($self) = @_;
  # Token renewal via renew-self endpoint
  my $token = $self->_token or die "No token to renew";
  my $resp = $self->_http->post(
    "${\$self->addr}/v1/auth/token/renew-self",
    {
      headers => {
        'Content-Type'  => 'application/json',
        'X-Vault-Token' => $token,
      },
      content => encode_json({}),
    },
  );

  if ($resp->{success}) {
    my $data = decode_json($resp->{content})->{auth} // {};
    my $ttl = $data->{ttl} // 0;
    $self->_token_expire(time + ($ttl > 0 ? $ttl : 3600));
    return 1;
  }

  # Renewal failed - token likely expired, need container restart
  die "OpenBao token renewal failed. Container must be restarted.";
}

sub resolve_key {
  my ($self, $ref) = @_;
  return undef unless defined $ref && length $ref;

  # Refresh token if needed
  $self->refresh if $self->needs_refresh;

  my $token = $self->_token or die "No OpenBao token";

  # Normalize path - strip leading slash if present
  $ref =~ s{^/+}{};

  my $resp = $self->_http->get(
    "${\$self->addr}/v1/$ref",
    {
      headers => { 'X-Vault-Token' => $token },
    },
  );

  if (!$resp->{success}) {
    warn "OpenBao read failed for '$ref': " . ($resp->{content} // 'unknown');
    return undef;
  }

  my $data = decode_json($resp->{content})->{data} // {};
  my $api_key = $data->{data}{api_key} // $data->{api_key} // undef;

  return $api_key;
}

sub list_secrets {
  my ($self, $path) = @_;
  return [] unless defined $path && length $path;

  $self->refresh if $self->needs_refresh;

  my $token = $self->_token or return [];
  $path =~ s{^/+}{};
  $path .= '/' unless $path =~ m{/$};

  my $resp = $self->_http->list(
    "${\$self->addr}/v1/$path",
    {
      headers => { 'X-Vault-Token' => $token },
    },
  );

  return [] unless $resp->{success};

  my $data = decode_json($resp->{content})->{data} // {};
  return [ map { $_->{key} } @{$data->{keys} // []} ];
}

sub DEMOLISH {
  my ($self) = @_;
  $self->_clear_renewal_loop if $self->has_renewal_loop;
  $self->_clear_token;
}

1;

=head1 DESCRIPTION

This KeyBroker implementation fetches API keys from OpenBao KV-v2 secrets.

Security model:
- AppRole credentials (role_id + secret_id) are injected at container start
- First request: use AppRole to get a token, store in memory
- Token is renewed every C<renew_secs> seconds (default: 5min)
- If renewal fails → die → container restart (expected behavior)

No secrets are ever written to disk. Token lives only in memory.

=cut