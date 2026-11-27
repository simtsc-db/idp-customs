-- Governance (idempotent, runs after each refresh): tags, Genie column comments, app grants.

USE CATALOG IDENTIFIER(:catalog);
USE SCHEMA IDENTIFIER(:schema);

-- tags
ALTER SCHEMA IDENTIFIER(:schema) SET TAGS ('domain' = 'operations', 'business_unit' = 'Operations', 'data_origin' = 'synthetic_demo');
ALTER MATERIALIZED VIEW gold_permit_drafts SET TAGS ('layer' = 'gold', 'classification' = 'confidential', 'customs_classification' = 'sen_norm_simulated');
ALTER MATERIALIZED VIEW gold_pack_checks   SET TAGS ('layer' = 'gold', 'classification' = 'confidential', 'customs_classification' = 'sen_norm_simulated');
ALTER MATERIALIZED VIEW gold_permit_items  SET TAGS ('layer' = 'gold', 'classification' = 'confidential', 'customs_classification' = 'sen_norm_simulated');
ALTER MATERIALIZED VIEW ref_fta_rules      SET TAGS ('layer' = 'silver', 'classification' = 'internal', 'rule_owner' = 'trade_division');
ALTER TABLE bronze_documents SET TAGS ('layer' = 'bronze', 'classification' = 'confidential');
ALTER TABLE silver_invoices SET TAGS ('layer' = 'silver', 'classification' = 'confidential');
ALTER TABLE silver_packing_lists SET TAGS ('layer' = 'silver', 'classification' = 'confidential');
ALTER TABLE silver_certificates_of_origin SET TAGS ('layer' = 'silver', 'classification' = 'confidential');
ALTER TABLE silver_invoices ALTER COLUMN buyer_uen SET TAGS ('sensitivity' = 'internal', 'business_identifier' = 'uen');

-- column comments (Genie context)
COMMENT ON COLUMN gold_permit_drafts.pack_id IS 'Trader permit pack identifier (PP-nnnn). One pack = invoice + packing list + Certificate of Origin.';
COMMENT ON COLUMN gold_permit_drafts.status IS 'AUTO_CLEARED = every automated check passed, permit pre-filled, no officer action; NEEDS_REVIEW = at least one check failed, routed to an officer.';
COMMENT ON COLUMN gold_permit_drafts.priority IS 'Review priority from the most severe failed check: high (FTA rule or HS code), medium (cross-document mismatch), low (low extraction confidence), none.';
COMMENT ON COLUMN gold_permit_drafts.exception_count IS 'Number of failed automated checks for the pack.';
COMMENT ON COLUMN gold_permit_drafts.fta_rule_exceptions IS 'Failed FTA origin rule checks (R01 member origin, R02 RVC threshold, R03 CoO issue window, R04 direct consignment).';
COMMENT ON COLUMN gold_permit_drafts.cross_document_exceptions IS 'Failed cross-document checks (X01 invoice reference, X02 quantities, X03 HS codes, X04 value, X05 consignee).';
COMMENT ON COLUMN gold_permit_drafts.failed_checks IS 'Pipe-separated list of failed check codes and names.';
COMMENT ON COLUMN gold_permit_drafts.importer_name IS 'Singapore importer (trader) declaring the permit; from the invoice buyer.';
COMMENT ON COLUMN gold_permit_drafts.importer_uen IS 'Importer UEN (synthetic).';
COMMENT ON COLUMN gold_permit_drafts.exporter_name IS 'Overseas supplier / exporter from the invoice.';
COMMENT ON COLUMN gold_permit_drafts.exporter_country IS 'ISO-2 country of the exporter.';
COMMENT ON COLUMN gold_permit_drafts.declared_value IS 'Invoice total in the invoice currency (see currency). Not converted to SGD.';
COMMENT ON COLUMN gold_permit_drafts.preferential_scheme IS 'FTA under which preferential tariff is claimed: ATIGA, CSFTA or RCEP.';
COMMENT ON COLUMN gold_permit_drafts.origin_country IS 'ISO-2 country of origin stated on the Certificate of Origin.';
COMMENT ON COLUMN gold_permit_drafts.shipment_date IS 'Shipment / ETD date from the invoice. Use for monthly reporting.';
COMMENT ON COLUMN gold_permit_drafts.min_field_confidence IS 'Lowest ai_extract confidence (0-1) across all fields of the three documents.';
COMMENT ON COLUMN gold_pack_checks.check_code IS 'C01 completeness; X01-X05 cross-document; R01-R04 FTA origin rules; E01 extraction confidence.';
COMMENT ON COLUMN gold_pack_checks.passed IS 'false = the check failed and the officer must review the pack.';
COMMENT ON COLUMN gold_pack_checks.category IS 'completeness, cross_document, fta_rule or extraction.';
COMMENT ON COLUMN gold_pack_checks.detail IS 'Human-readable evidence for the check result, quoting the extracted values.';

-- App access: the review app's service principal reads exactly the three gold tables.
DECLARE OR REPLACE VARIABLE app_principal STRING
  DEFAULT IF(:app_sp RLIKE '^[0-9a-fA-F-]{36}$', :app_sp, raise_error('invalid app_sp'));
DECLARE OR REPLACE VARIABLE grant_sql STRING;
SET VAR grant_sql = 'GRANT USE SCHEMA ON SCHEMA ' || :schema || ' TO `' || app_principal || '`';
EXECUTE IMMEDIATE grant_sql;
SET VAR grant_sql = 'GRANT SELECT ON TABLE gold_permit_drafts TO `' || app_principal || '`';
EXECUTE IMMEDIATE grant_sql;
SET VAR grant_sql = 'GRANT SELECT ON TABLE gold_pack_checks TO `' || app_principal || '`';
EXECUTE IMMEDIATE grant_sql;
SET VAR grant_sql = 'GRANT SELECT ON TABLE gold_permit_items TO `' || app_principal || '`';
EXECUTE IMMEDIATE grant_sql;
