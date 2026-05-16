-- PostgreSQL Schema for Langertha::Skeid Usage Tracking
-- Version: 0.001

-- Usage events table - stores every LLM API call
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

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_usage_events_created_at ON usage_events(created_at);
CREATE INDEX IF NOT EXISTS idx_usage_events_api_key_id ON usage_events(api_key_id);
CREATE INDEX IF NOT EXISTS idx_usage_events_model ON usage_events(model);
CREATE INDEX IF NOT EXISTS idx_usage_events_provider ON usage_events(provider);
CREATE INDEX IF NOT EXISTS idx_usage_events_node_id ON usage_events(node_id);

-- Customer usage summary ( materialized view approach for fast lookups )
CREATE TABLE IF NOT EXISTS customer_usage_summary (
  api_key_id TEXT NOT NULL PRIMARY KEY,
  total_requests INTEGER NOT NULL DEFAULT 0,
  total_input_tokens INTEGER NOT NULL DEFAULT 0,
  total_output_tokens INTEGER NOT NULL DEFAULT 0,
  total_cost_usd NUMERIC(12, 6) NOT NULL DEFAULT 0,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Function to update customer summary on insert
CREATE OR REPLACE FUNCTION update_customer_usage_summary()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO customer_usage_summary (api_key_id, total_requests, total_input_tokens, total_output_tokens, total_cost_usd, last_seen_at)
  VALUES (NEW.api_key_id, 1, NEW.input_tokens, NEW.output_tokens, NEW.cost_total_usd, NEW.created_at)
  ON CONFLICT (api_key_id) DO UPDATE SET
    total_requests = customer_usage_summary.total_requests + 1,
    total_input_tokens = customer_usage_summary.total_input_tokens + NEW.input_tokens,
    total_output_tokens = customer_usage_summary.total_output_tokens + NEW.output_tokens,
    total_cost_usd = customer_usage_summary.total_cost_usd + NEW.cost_total_usd,
    last_seen_at = GREATEST(customer_usage_summary.last_seen_at, NEW.created_at);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to keep summary updated
DROP TRIGGER IF EXISTS trig_usage_events ON usage_events;
CREATE TRIGGER trig_usage_events
  AFTER INSERT ON usage_events
  FOR EACH ROW EXECUTE FUNCTION update_customer_usage_summary();