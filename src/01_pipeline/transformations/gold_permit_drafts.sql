-- Layer: gold
-- Gold: pack-level reconciliation, FTA rule checks, auto-populated permit drafts.
-- Pure SQL over persisted extractions: no AI calls here, so re-running is cheap.

CREATE OR REFRESH MATERIALIZED VIEW gold_permit_drafts (
  CONSTRAINT one_status EXPECT (status IN ('AUTO_CLEARED', 'NEEDS_REVIEW'))
)
COMMENT 'Auto-populated import permit draft per trader pack. status = AUTO_CLEARED when every check passes, else NEEDS_REVIEW with the failed checks listed.'
AS
WITH agg AS (
  SELECT pack_id,
    count_if(NOT passed)                                                  AS exception_count,
    count_if(NOT passed AND category = 'fta_rule')                        AS fta_rule_exceptions,
    count_if(NOT passed AND category = 'cross_document')                  AS cross_document_exceptions,
    max(CASE WHEN NOT passed AND severity = 'high' THEN 3 WHEN NOT passed AND severity = 'medium' THEN 2 WHEN NOT passed THEN 1 ELSE 0 END) AS sev_rank,
    array_join(array_sort(collect_list(CASE WHEN NOT passed THEN concat(check_code, ' ', check_name) END)), ' | ') AS failed_checks
  FROM gold_pack_checks GROUP BY pack_id
)
SELECT
  d.pack_id,
  CASE WHEN a.exception_count = 0 THEN 'AUTO_CLEARED' ELSE 'NEEDS_REVIEW' END AS status,
  CASE a.sev_rank WHEN 3 THEN 'high' WHEN 2 THEN 'medium' WHEN 1 THEN 'low' ELSE 'none' END AS priority,
  a.exception_count, a.fta_rule_exceptions, a.cross_document_exceptions, a.failed_checks,
  d.buyer_name   AS importer_name,
  d.buyer_uen    AS importer_uen,
  d.seller_name  AS exporter_name,
  d.seller_country AS exporter_country,
  d.invoice_number, d.invoice_date, d.incoterm, d.currency,
  d.total_amount AS declared_value,
  d.inv_port_of_loading AS port_of_loading,
  d.shipment_date,
  d.fta AS preferential_scheme,
  d.certificate_number,
  d.origin_country,
  size(d.inv_lines) AS item_count,
  d.min_field_confidence,
  d.invoice_file, d.packing_list_file, d.coo_file,
  current_timestamp() AS drafted_at
FROM gold_pack_documents d JOIN agg a ON a.pack_id = d.pack_id;
