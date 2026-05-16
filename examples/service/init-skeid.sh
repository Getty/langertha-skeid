#!/bin/bash
set -e

echo "=== Skeid Init Script ==="

# Wait for OpenBao to be ready
echo "Waiting for OpenBao..."
until curl -sf "${OPENBAO_ADDR}/v1/sys/health" > /dev/null 2>&1; do
  sleep 2
done
echo "OpenBao is ready"

# Use root token for setup
export BAO_TOKEN="${OPENBAO_ROOT_TOKEN:-skeid-root-token}"

echo "=== Setting up AppRole for Skeid ==="

# Enable AppRole auth method
curl -sf -X POST \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -H "Content-Type: application/json" \
  "${OPENBAO_ADDR}/v1/sys/auth/approle" \
  -d '{"type": "approle"}' || true

# Create AppRole for Skeid
ROLE_NAME="skeid-service"
curl -sf -X POST \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -H "Content-Type: application/json" \
  "${OPENBAO_ADDR}/v1/auth/approle/role/${ROLE_NAME}" \
  -d '{
    "token_ttl": "1h",
    "token_max_ttl": "24h",
    "token_policies": ["skeid-keys"]
  }' || true

# Get Role ID
ROLE_ID=$(curl -sf -X GET \
  -H "X-Vault-Token: $BAO_TOKEN" \
  "${OPENBAO_ADDR}/v1/auth/approle/role/${ROLE_NAME}/role-id" \
  | jq -r '.data.role_id')

# Generate new Secret ID (this is the one-time use credential)
SECRET_ID=$(curl -sf -X POST \
  -H "X-Vault-Token: $BAO_TOKEN" \
  "${OPENBAO_ADDR}/v1/auth/approle/role/${ROLE_NAME}/secret-id" \
  | jq -r '.data.secret_id')

echo "Role ID: $ROLE_ID"
echo "Secret ID: $SECRET_ID (save this - only shown once!)"
echo ""
echo "Add these to your docker-compose.yml or .env:"
echo "OPENBAO_ROLE_ID=$ROLE_ID"
echo "OPENBAO_SECRET_ID=$SECRET_ID"

# Create policy for Skeid to read keys
cat > /tmp/skeid-policy.hcl << 'POLICY'
path "secret/skeid/*" {
  capabilities = ["read", "list"]
}
POLICY

curl -sf -X PUT \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -H "Content-Type: application/json" \
  "${OPENBAO_ADDR}/v1/sys/policies/acl/skeid-keys" \
  -d "{\"policy\": $(cat /tmp/skeid-policy.hcl | jq -Rs .)}" || true

echo "=== Storing LLM Provider Keys ==="

# Store OpenAI key if provided
if [ -n "$SKEID_OPENAI_KEY" ]; then
  curl -sf -X POST \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -H "Content-Type: application/json" \
    "${OPENBAO_ADDR}/v1/secret/data/skeid/remote/openai" \
    -d "{\"data\": {\"api_key\": \"$SKEID_OPENAI_KEY\"}}"
  echo "Stored OpenAI key"
fi

# Store Anthropic key if provided
if [ -n "$SKEID_ANTHROPIC_KEY" ]; then
  curl -sf -X POST \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -H "Content-Type: application/json" \
    "${OPENBAO_ADDR}/v1/secret/data/skeid/remote/anthropic" \
    -d "{\"data\": {\"api_key\": \"$SKEID_ANTHROPIC_KEY\"}}"
  echo "Stored Anthropic key"
fi

echo "=== Creating Customer Key Entries ==="

# Create some example customer keys
for customer in alice bob charlie; do
  curl -sf -X POST \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -H "Content-Type: application/json" \
    "${OPENBAO_ADDR}/v1/secret/data/skeid/customer/${customer}" \
    -d "{\"data\": {\"api_key\": \"sk-${customer}-$(date +%s)\", \"active\": true}}"
  echo "Created key for $customer"
done

echo "=== Setting up PostgreSQL Schema ==="

# Wait for postgres
echo "Waiting for PostgreSQL..."
until PGPASSWORD=skeid_password_change_me psql -h postgres -U skeid -d skeid -c "SELECT 1" > /dev/null 2>&1; do
  sleep 2
done

# Create schema from file
if [ -f /etc/skeid/usage_schema.sql ]; then
  PGPASSWORD=skeid_password_change_me psql -h postgres -U skeid -d skeid -f /etc/skeid/usage_schema.sql
else
  # Inline schema creation
  PGPASSWORD=skeid_password_change_me psql -h postgres -U skeid -d skeid << 'SQL'
CREATE TABLE IF NOT EXISTS usage_events (
  id BIGSERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  request_id TEXT NOT NULL DEFAULT '',
  api_format TEXT NOT NULL DEFAULT '',
  endpoint TEXT NOT NULL DEFAULT '',
  api_key_id TEXT NOT NULL DEFAULT '',
  provider TEXT NOT NULL DEFAULT '',
  engine TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT '',
  node_id TEXT NOT NULL DEFAULT '',
  route_url TEXT NOT NULL DEFAULT '',
  status_code INTEGER NOT NULL DEFAULT 0,
  ok BOOLEAN NOT NULL DEFAULT FALSE,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  total_tokens INTEGER NOT NULL DEFAULT 0,
  tool_calls INTEGER NOT NULL DEFAULT 0,
  cost_input_usd NUMERIC(12, 6) NOT NULL DEFAULT 0,
  cost_output_usd NUMERIC(12, 6) NOT NULL DEFAULT 0,
  cost_total_usd NUMERIC(12, 6) NOT NULL DEFAULT 0,
  error_type TEXT NOT NULL DEFAULT '',
  error_message TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_usage_events_created_at ON usage_events(created_at);
CREATE INDEX IF NOT EXISTS idx_usage_events_api_key_id ON usage_events(api_key_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_model ON usage_events(model);
SQL
  echo "PostgreSQL schema created"
fi

echo ""
echo "=== Init Complete ==="
echo ""
echo "Next steps:"
echo "1. Copy the OPENBAO_ROLE_ID and OPENBAO_SECRET_ID from above"
echo "2. Add them to your docker-compose.yml or .env file"
echo "3. Restart skeid with the AppRole credentials"
echo "4. Test with: curl -H 'x-skeid-key-id: alice' http://localhost:8090/v1/chat/completions ..."