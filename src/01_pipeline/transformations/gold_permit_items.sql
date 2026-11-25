-- Gold: permit line items with the CoO origin criterion.
CREATE OR REFRESH MATERIALIZED VIEW gold_permit_items
COMMENT 'Permit line items: invoice lines enriched with the CoO origin criterion for the same HS code.'
AS
SELECT d.pack_id, pos + 1 AS line_no, col.hs_code, col.description, col.quantity, col.unit,
       col.unit_price, col.amount, d.currency,
       filter(d.coo_lines, c -> regexp_replace(c.hs_code, '[^0-9]', '') = regexp_replace(col.hs_code, '[^0-9]', ''))[0].origin_criterion AS origin_criterion,
       filter(d.coo_lines, c -> regexp_replace(c.hs_code, '[^0-9]', '') = regexp_replace(col.hs_code, '[^0-9]', ''))[0].rvc_percent AS rvc_percent,
       col.conf AS extraction_confidence
FROM gold_pack_documents d
LATERAL VIEW posexplode(d.inv_lines) li AS pos, col;
