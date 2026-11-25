-- Layer: bronze
-- Bronze: every trader document that lands in the inbox is parsed exactly once.
-- ai_parse_document (v2.0) handles PDFs and scanned images (OCR + layout).
-- AI figure descriptions are disabled ('') to keep cost per document low.

CREATE OR REFRESH MATERIALIZED VIEW ref_fta_rules
COMMENT 'FTA origin rules used by the automated checks (illustrative, simplified). member_countries is a pipe-separated ISO-2 list.'
AS SELECT
  fta_code, fta_name, coo_form,
  split(member_countries, '\\|')                     AS member_countries,
  CAST(rvc_threshold_pct AS DOUBLE)                  AS rvc_threshold_pct,
  CAST(max_days_issue_after_shipment AS INT)         AS max_days_issue_after_shipment,
  CAST(requires_direct_consignment AS BOOLEAN)       AS requires_direct_consignment
FROM read_files('/Volumes/${catalog}/${schema}/permit_packs/reference/fta_rules.csv', format => 'csv', header => true);
