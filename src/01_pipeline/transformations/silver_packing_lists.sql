-- Layer: silver
-- Silver: classify each document, then extract a typed schema per document type.
-- ai_extract v2.1 returns value + confidence_score + citation_ids per field.
-- Each AI call runs once per document; results are persisted, never re-run on query.

CREATE OR REFRESH STREAMING TABLE silver_packing_lists (
  CONSTRAINT extracted_without_error EXPECT (extract_error IS NULL),
  CONSTRAINT has_invoice_reference EXPECT (invoice_reference IS NOT NULL)
)
COMMENT 'Fields extracted from packing lists (ai_extract v2.1).'
AS WITH x AS (
  SELECT pack_id, file_name, source_path,
    ai_extract(parsed, '{
      "packing_list_number":   {"type": "string"},
      "invoice_reference":     {"type": "string", "description": "Invoice number this packing list refers to"},
      "shipper":               {"type": "string"},
      "consignee":             {"type": "string"},
      "total_packages":        {"type": "integer"},
      "total_gross_weight_kg": {"type": "number"},
      "line_items": {"type": "array", "items": {"type": "object", "properties": {
          "hs_code":         {"type": "string", "description": "HS code exactly as printed"},
          "quantity":        {"type": "number"},
          "packages":        {"type": "integer"},
          "gross_weight_kg": {"type": "number"}}}}
    }', map('version', '2.1', 'enableConfidenceScores', 'true', 'enableCitations', 'true',
            'instructions', 'Customs trade permit supporting document. Copy company names, reference numbers and HS codes exactly as printed, character for character; never correct or standardise spelling. Normalise dates to YYYY-MM-DD. Documents may be bilingual English/Chinese; return English values.')) AS x
  FROM STREAM silver_documents
  WHERE doc_type = 'packing_list'
)
SELECT pack_id, file_name, source_path,
  x:response:packing_list_number:value::STRING  AS packing_list_number,
  x:response:invoice_reference:value::STRING    AS invoice_reference,
  x:response:shipper:value::STRING              AS shipper,
  x:response:consignee:value::STRING            AS consignee,
  x:response:total_packages:value::INT          AS total_packages,
  x:response:total_gross_weight_kg:value::DOUBLE AS total_gross_weight_kg,
  transform(CAST(x:response:line_items AS ARRAY<VARIANT>), li -> named_struct(
    'hs_code', li:hs_code:value::STRING, 'quantity', li:quantity:value::DOUBLE,
    'packages', li:packages:value::INT, 'gross_weight_kg', li:gross_weight_kg:value::DOUBLE,
    'conf', least(li:hs_code:confidence_score::DOUBLE, li:quantity:confidence_score::DOUBLE)
  )) AS line_items,
  array(
    named_struct('field', 'invoice_reference', 'conf', x:response:invoice_reference:confidence_score::DOUBLE),
    named_struct('field', 'consignee',         'conf', x:response:consignee:confidence_score::DOUBLE),
    named_struct('field', 'total_packages',    'conf', x:response:total_packages:confidence_score::DOUBLE)
  ) AS field_confidence,
  x:error_message::STRING AS extract_error,
  x AS raw_extract
FROM x;
