-- Gold: one row per pack joining invoice, packing list and CoO.
CREATE OR REFRESH MATERIALIZED VIEW gold_pack_documents
COMMENT 'One row per permit pack joining the extracted invoice, packing list and Certificate of Origin. Basis for all checks.'
AS
WITH packs AS (SELECT DISTINCT pack_id FROM silver_documents)
SELECT
  p.pack_id,
  i.invoice_number, i.invoice_date, i.seller_name, i.seller_country, i.buyer_name, i.buyer_uen,
  i.currency, i.incoterm, i.port_of_loading AS inv_port_of_loading, i.shipment_date, i.total_amount,
  i.line_items AS inv_lines, i.field_confidence AS inv_conf, i.file_name AS invoice_file,
  l.invoice_reference AS pl_invoice_reference, l.consignee AS pl_consignee, l.total_packages,
  l.total_gross_weight_kg, l.line_items AS pl_lines, l.field_confidence AS pl_conf, l.file_name AS packing_list_file,
  c.certificate_number, c.fta, c.exporter AS coo_exporter, c.consignee AS coo_consignee, c.origin_country,
  c.invoice_reference AS coo_invoice_reference, c.invoice_value AS coo_invoice_value,
  c.currency AS coo_currency, c.issue_date AS coo_issue_date, c.port_of_loading AS coo_port_of_loading,
  c.line_items AS coo_lines, c.field_confidence AS coo_conf, c.file_name AS coo_file,
  array_min(
    concat(
      coalesce(transform(i.field_confidence, f -> f.conf), array()),
      coalesce(transform(i.line_items, x -> x.conf), array()),
      coalesce(transform(l.field_confidence, f -> f.conf), array()),
      coalesce(transform(c.field_confidence, f -> f.conf), array()),
      coalesce(transform(c.line_items, x -> x.conf), array())
    )
  ) AS min_field_confidence,
  concat(
    coalesce(transform(filter(i.field_confidence, f -> f.conf < 0.9), f -> concat('invoice.', f.field)), array()),
    coalesce(transform(filter(l.field_confidence, f -> f.conf < 0.9), f -> concat('packing_list.', f.field)), array()),
    coalesce(transform(filter(c.field_confidence, f -> f.conf < 0.9), f -> concat('coo.', f.field)), array())
  ) AS low_confidence_fields
FROM packs p
LEFT JOIN silver_invoices i              ON i.pack_id = p.pack_id
LEFT JOIN silver_packing_lists l         ON l.pack_id = p.pack_id
LEFT JOIN silver_certificates_of_origin c ON c.pack_id = p.pack_id;
