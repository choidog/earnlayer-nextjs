-- API Logs Table Schema
CREATE TABLE IF NOT EXISTS api_logs (
  id SERIAL PRIMARY KEY,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  level VARCHAR(20) NOT NULL,
  endpoint VARCHAR(500) NOT NULL,
  method VARCHAR(10),
  message TEXT NOT NULL,
  details JSONB,
  request_id VARCHAR(100),
  status_code INTEGER,
  duration INTEGER,
  user_id VARCHAR(100),
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_api_logs_timestamp ON api_logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_api_logs_level ON api_logs(level);
CREATE INDEX IF NOT EXISTS idx_api_logs_endpoint ON api_logs(endpoint);
CREATE INDEX IF NOT EXISTS idx_api_logs_request_id ON api_logs(request_id);
CREATE INDEX IF NOT EXISTS idx_api_logs_user_id ON api_logs(user_id);

-- Add comment for documentation
COMMENT ON TABLE api_logs IS 'Real-time API logging for debugging and monitoring';