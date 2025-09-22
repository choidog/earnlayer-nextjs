-- Trigger DDL for schema public
CREATE TRIGGER update_ad_campaigns_updated_at BEFORE UPDATE ON ad_campaigns FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER sync_campaign_spent_on_impression AFTER INSERT ON ad_impressions FOR EACH ROW EXECUTE FUNCTION sync_campaign_spent_and_status();
CREATE TRIGGER update_ad_impressions_updated_at BEFORE UPDATE ON ad_impressions FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE CONSTRAINT TRIGGER trg_ads_campaign_active AFTER INSERT OR UPDATE OF status, campaign_id ON ads DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION enforce_campaign_active_for_ads();
CREATE TRIGGER update_ads_updated_at BEFORE UPDATE ON ads FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_advertisers_updated_at BEFORE UPDATE ON advertisers FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_content_updated_at BEFORE UPDATE ON content FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER refresh_cpc_rates_on_creator_affiliate_codes AFTER INSERT OR DELETE OR UPDATE ON creator_affiliate_codes FOR EACH ROW EXECUTE FUNCTION trigger_refresh_effective_cpc_rates();
CREATE TRIGGER update_creator_affiliate_codes_updated_at BEFORE UPDATE ON creator_affiliate_codes FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_creator_category_prefs_updated_at BEFORE UPDATE ON creator_category_preferences FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_creator_settings_updated_at BEFORE UPDATE ON creator_settings FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_creators_updated_at BEFORE UPDATE ON creators FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_default_ad_relationship_updated_at BEFORE UPDATE ON default_ad_relationship FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE CONSTRAINT TRIGGER trg_embeddings_source_fk AFTER INSERT OR UPDATE OF source_table, source_id ON embeddings DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION validate_embeddings_source_fk();
CREATE TRIGGER update_payouts_updated_at BEFORE UPDATE ON payouts FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
