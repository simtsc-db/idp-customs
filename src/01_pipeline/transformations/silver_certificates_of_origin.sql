-- Layer: silver
-- Silver: classify each document, then extract a typed schema per document type.
-- ai_extract v2.1 returns value + confidence_score + citation_ids per field.
-- Each AI call runs once per document; results are persisted, never re-run on query.

CREATE OR REFRESH STREAMING TABLE silver_certificates_of_origin (
  CONSTRAINT extracted_without_error EXPECT (extract_error IS NULL),
  CONSTRAINT has_certificate_number EXPECT (certificate_number IS NOT NULL),
  CONSTRAINT has_issue_date EXPECT (issue_date IS NOT NULL)
)
COMMENT 'Fields extracted from Certificates of Origin (ai_extract v2.1).'
AS WITH x AS (
  SELECT pack_id, file_name, source_path,
    ai_extract(parsed, '{
      "certificate_number": {"type": "string", "description": "CoO reference number"},
      "fta":                {"type": "enum", "labels": ["ATIGA","CSFTA","RCEP","OTHER"], "description": "Free trade agreement the certificate is issued under"},
      "exporter":           {"type": "string"},
      "consignee":          {"type": "string", "description": "Consignee company name only, without address"},
      "origin_country":     {"type": "enum", "labels": ["SG","MY","TH","VN","ID","PH","BN","KH","LA","MM","CN","JP","KR","AU","NZ","IN","US","OTHER"], "description": "ISO-2 country of origin stated on the certificate"},
      "invoice_reference":  {"type": "string"},
      "invoice_value":      {"type": "number"},
      "currency":           {"type": "enum", "labels": ["USD","SGD","CNY","MYR","THB","EUR","OTHER"]},
      "issue_date":         {"type": "string", "description": "Date the certificate was issued, ISO format YYYY-MM-DD"},
      "port_of_loading":    {"type": "string", "description": "Port of loading (city/port name only)"},
      "line_items": {"type": "array", "items": {"type": "object", "properties": {
          "hs_code":          {"type": "string", "description": "HS code exactly as printed"},
          "quantity":         {"type": "number"},
          "origin_criterion": {"type": "enum", "labels": ["WO","RVC","CTH","CTSH","PE","OTHER"]},
          "rvc_percent":      {"type": "number", "description": "Regional value content percentage if the criterion is RVC, else null"}}}}
    }', map('version', '2.1', 'enableConfidenceScores', 'true', 'enableCitations', 'true',
            'instructions', 'Customs trade permit supporting document. Copy company names, reference numbers and HS codes exactly as printed, character for character; never correct or standardise spelling. Normalise dates to YYYY-MM-DD. Documents may be bilingual English/Chinese; return English values.')) AS x
  FROM STREAM silver_documents
  WHERE doc_type = 'certificate_of_origin'
)
SELECT pack_id, file_name, source_path,
  x:response:certificate_number:value::STRING AS certificate_number,
  x:response:fta:value::STRING                AS fta,
  x:response:exporter:value::STRING           AS exporter,
  x:response:consignee:value::STRING          AS consignee,
  x:response:origin_country:value::STRING     AS origin_country,
  x:response:invoice_reference:value::STRING  AS invoice_reference,
  x:response:invoice_value:value::DOUBLE      AS invoice_value,
  x:response:currency:value::STRING           AS currency,
  coalesce(try_to_date(x:response:issue_date:value::STRING, 'yyyy-MM-dd'), try_to_date(x:response:issue_date:value::STRING, 'dd-MM-yyyy'), try_to_date(x:response:issue_date:value::STRING, 'dd/MM/yyyy'), try_to_date(x:response:issue_date:value::STRING, 'd MMM yyyy'), try_to_date(x:response:issue_date:value::STRING, 'MMMM d, yyyy'), try_to_date(x:response:issue_date:value::STRING, 'yyyy年MM月dd日')) AS issue_date,
  x:response:port_of_loading:value::STRING    AS port_of_loading,
  transform(CAST(x:response:line_items AS ARRAY<VARIANT>), li -> named_struct(
    'hs_code', li:hs_code:value::STRING, 'quantity', li:quantity:value::DOUBLE,
    'origin_criterion', li:origin_criterion:value::STRING, 'rvc_percent', li:rvc_percent:value::DOUBLE,
    'conf', least(li:hs_code:confidence_score::DOUBLE, li:origin_criterion:confidence_score::DOUBLE)
  )) AS line_items,
  array(
    named_struct('field', 'certificate_number', 'conf', x:response:certificate_number:confidence_score::DOUBLE),
    named_struct('field', 'fta',                'conf', x:response:fta:confidence_score::DOUBLE),
    named_struct('field', 'consignee',          'conf', x:response:consignee:confidence_score::DOUBLE),
    named_struct('field', 'origin_country',     'conf', x:response:origin_country:confidence_score::DOUBLE),
    named_struct('field', 'invoice_value',      'conf', x:response:invoice_value:confidence_score::DOUBLE),
    named_struct('field', 'issue_date',         'conf', x:response:issue_date:confidence_score::DOUBLE)
  ) AS field_confidence,
  x:error_message::STRING AS extract_error,
  x AS raw_extract
FROM x;
