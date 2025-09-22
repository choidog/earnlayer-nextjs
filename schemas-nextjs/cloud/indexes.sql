-- Non-constraint index DDL for schema public
CREATE INDEX idx_banner_dismissals_user_id ON agreement_banner_dismissals USING btree (user_id);
CREATE INDEX idx_agreement_versions_active ON agreement_versions USING btree (is_active) WHERE is_active = true;
CREATE INDEX idx_api_key_usage_api_key_id ON api_key_usage USING btree (api_key_id);
CREATE INDEX idx_api_key_usage_created_at ON api_key_usage USING btree (created_at);
CREATE INDEX idx_api_keys_key ON api_keys USING btree (key);
CREATE INDEX idx_api_keys_user_id ON api_keys USING btree (user_id);
CREATE INDEX idx_api_logs_endpoint ON api_logs USING btree (endpoint);
CREATE INDEX idx_api_logs_level ON api_logs USING btree (level);
CREATE INDEX idx_api_logs_request_id ON api_logs USING btree (request_id);
CREATE INDEX idx_api_logs_timestamp ON api_logs USING btree ("timestamp" DESC);
CREATE INDEX idx_api_logs_user_id ON api_logs USING btree (user_id);
CREATE INDEX idx_user_agreements_user_id ON user_agreements USING btree (user_id);
CREATE INDEX idx_user_agreements_version_id ON user_agreements USING btree (agreement_version_id);
CREATE INDEX idx_users_email ON users USING btree (email);
