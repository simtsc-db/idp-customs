-- Layer: gold
-- Gold: pack-level reconciliation, FTA rule checks, auto-populated permit drafts.
-- Pure SQL over persisted extractions: no AI calls here, so re-running is cheap.

CREATE OR REFRESH MATERIALIZED VIEW gold_pack_checks
COMMENT 'One row per pack per automated check. passed = false means the officer must review. Categories: completeness, cross_document, fta_rule, extraction.'
AS
WITH j AS (
  SELECT d.*, r.fta_code AS rule_fta, r.member_countries, r.rvc_threshold_pct, r.max_days_issue_after_shipment,
         pt.country_code AS loading_country,
         regexp_replace(lower(coalesce(d.buyer_name, '')), '[^a-z0-9]|singapore|pte|ltd', '') AS buyer_norm,
         regexp_replace(lower(coalesce(d.coo_consignee, '')), '[^a-z0-9]|singapore|pte|ltd', '') AS coo_consignee_norm,
         regexp_replace(lower(coalesce(d.pl_consignee, '')), '[^a-z0-9]|singapore|pte|ltd', '') AS pl_consignee_norm,
         transform(d.inv_lines, x -> regexp_replace(x.hs_code, '[^0-9]', '')) AS inv_hs,
         transform(d.coo_lines, x -> regexp_replace(x.hs_code, '[^0-9]', '')) AS coo_hs
  FROM gold_pack_documents d
  LEFT JOIN ref_fta_rules r ON r.fta_code = d.fta
  LEFT JOIN ref_ports pt    ON pt.port_key = lower(trim(d.inv_port_of_loading))
),
checks AS (
  SELECT pack_id, 'C01' AS check_code, 'All three documents present' AS check_name, 'completeness' AS category, 'high' AS severity,
    (invoice_file IS NOT NULL AND packing_list_file IS NOT NULL AND coo_file IS NOT NULL) AS passed,
    concat_ws(', ', CASE WHEN invoice_file IS NULL THEN 'invoice missing' END,
                    CASE WHEN packing_list_file IS NULL THEN 'packing list missing' END,
                    CASE WHEN coo_file IS NULL THEN 'certificate of origin missing' END) AS detail
  FROM j
  UNION ALL
  SELECT pack_id, 'X01', 'Invoice referenced consistently', 'cross_document', 'medium',
    regexp_replace(upper(pl_invoice_reference), '[^A-Z0-9]', '') = regexp_replace(upper(invoice_number), '[^A-Z0-9]', '')
      AND regexp_replace(upper(coo_invoice_reference), '[^A-Z0-9]', '') = regexp_replace(upper(invoice_number), '[^A-Z0-9]', ''),
    concat('Invoice ', invoice_number, '; packing list refers to ', coalesce(pl_invoice_reference, '?'), '; CoO refers to ', coalesce(coo_invoice_reference, '?'))
  FROM j
  UNION ALL
  SELECT pack_id, 'X02', 'Quantities match invoice vs packing list', 'cross_document', 'medium',
    coalesce(forall(inv_lines, x -> x.quantity = filter(pl_lines, p -> regexp_replace(p.hs_code, '[^0-9]', '') = regexp_replace(x.hs_code, '[^0-9]', ''))[0].quantity), false),
    coalesce(nullif(concat_ws('; ', transform(
      filter(inv_lines, x -> NOT coalesce(x.quantity = filter(pl_lines, p -> regexp_replace(p.hs_code, '[^0-9]', '') = regexp_replace(x.hs_code, '[^0-9]', ''))[0].quantity, false)),
      x -> concat('HS ', x.hs_code, ': invoice ', cast(x.quantity AS STRING), ' vs packing list ',
                  coalesce(cast(filter(pl_lines, p -> regexp_replace(p.hs_code, '[^0-9]', '') = regexp_replace(x.hs_code, '[^0-9]', ''))[0].quantity AS STRING), 'not found')))), ''),
      'All line quantities agree')
  FROM j
  UNION ALL
  SELECT pack_id, 'X03', 'HS codes match invoice vs CoO', 'cross_document', 'high',
    array_sort(inv_hs) = array_sort(coo_hs),
    CASE WHEN array_sort(inv_hs) = array_sort(coo_hs) THEN 'HS codes agree'
         ELSE concat('Invoice only: ', array_join(array_except(transform(inv_lines, x -> x.hs_code), transform(coo_lines, x -> x.hs_code)), ', '),
                     ' | CoO only: ', array_join(array_except(transform(coo_lines, x -> x.hs_code), transform(inv_lines, x -> x.hs_code)), ', ')) END
  FROM j
  UNION ALL
  SELECT pack_id, 'X04', 'Invoice value matches CoO (within 1%)', 'cross_document', 'medium',
    abs(coo_invoice_value - total_amount) <= 0.01 * total_amount,
    concat('Invoice total ', currency, ' ', format_number(total_amount, 2), ' vs CoO ', coalesce(coo_currency, ''), ' ', format_number(coo_invoice_value, 2))
  FROM j
  UNION ALL
  SELECT pack_id, 'X05', 'Consignee matches importer', 'cross_document', 'medium',
    buyer_norm <> '' AND coo_consignee_norm = buyer_norm AND pl_consignee_norm = buyer_norm,
    concat('Invoice buyer: ', coalesce(buyer_name, '?'), ' | CoO consignee: ', coalesce(coo_consignee, '?'), ' | Packing list consignee: ', coalesce(pl_consignee, '?'))
  FROM j
  UNION ALL
  SELECT pack_id, 'R01', 'Origin country is an FTA member', 'fta_rule', 'high',
    coalesce(array_contains(member_countries, origin_country), false),
    concat('CoO under ', coalesce(fta, '?'), ' states origin ', coalesce(origin_country, '?'),
           CASE WHEN rule_fta IS NULL THEN ' (FTA not recognised)' ELSE '' END,
           CASE WHEN NOT coalesce(array_contains(member_countries, origin_country), false) THEN concat(', not a member of ', coalesce(fta, '?')) ELSE '' END)
  FROM j
  UNION ALL
  SELECT pack_id, 'R02', 'Regional value content meets threshold', 'fta_rule', 'high',
    coalesce(forall(filter(coo_lines, x -> x.origin_criterion = 'RVC'), x -> x.rvc_percent >= rvc_threshold_pct), false),
    coalesce(nullif(concat_ws('; ', transform(filter(coo_lines, x -> x.origin_criterion = 'RVC' AND NOT coalesce(x.rvc_percent >= rvc_threshold_pct, false)),
      x -> concat('HS ', x.hs_code, ': RVC ', cast(x.rvc_percent AS STRING), '% below ', cast(rvc_threshold_pct AS STRING), '% (', fta, ')'))), ''),
      'All RVC claims meet threshold')
  FROM j
  UNION ALL
  SELECT pack_id, 'R03', 'CoO issued within allowed window', 'fta_rule', 'medium',
    datediff(coo_issue_date, shipment_date) <= max_days_issue_after_shipment,
    CASE WHEN shipment_date IS NULL OR coo_issue_date IS NULL
         THEN concat('Cannot verify: ', CASE WHEN shipment_date IS NULL THEN 'shipment date not extracted from invoice' ELSE 'CoO issue date not extracted' END)
         ELSE concat('Shipped ', cast(shipment_date AS STRING), ', CoO issued ', cast(coo_issue_date AS STRING),
           ' (', cast(datediff(coo_issue_date, shipment_date) AS STRING), ' days after; max ', cast(max_days_issue_after_shipment AS STRING), ')') END
  FROM j
  UNION ALL
  SELECT pack_id, 'R04', 'Direct consignment from member country', 'fta_rule', 'high',
    coalesce(array_contains(member_countries, loading_country), false),
    concat('Port of loading ', coalesce(inv_port_of_loading, '?'), ' (', coalesce(loading_country, 'unknown port'), ') for ', coalesce(fta, '?'), ' claim')
  FROM j
  UNION ALL
  SELECT pack_id, 'E01', 'All fields extracted with high confidence (>= 0.9)', 'extraction', 'low',
    coalesce(min_field_confidence >= 0.9, false),
    CASE WHEN size(low_confidence_fields) = 0 THEN concat('Lowest field confidence ', format_number(min_field_confidence, 2))
         ELSE concat('Check: ', array_join(low_confidence_fields, ', ')) END
  FROM j
)
SELECT pack_id, check_code, check_name, category, severity, coalesce(passed, false) AS passed,
       coalesce(detail, 'Cannot verify: required field not extracted') AS detail
FROM checks;
