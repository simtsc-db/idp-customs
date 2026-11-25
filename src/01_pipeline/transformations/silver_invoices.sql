-- Silver: invoice fields via ai_extract v2.1 (value, confidence, citations).
CREATE OR REFRESH STREAMING TABLE silver_invoices (
  CONSTRAINT extracted_without_error EXPECT (extract_error IS NULL),
  CONSTRAINT has_invoice_number EXPECT (invoice_number IS NOT NULL),
  CONSTRAINT has_line_items EXPECT (size(line_items) > 0),
  CONSTRAINT lines_sum_to_total EXPECT (abs(aggregate(line_items, 0D, (acc, x) -> acc + coalesce(x.amount, 0D)) - total_amount) <= 0.05)
)
COMMENT 'Fields extracted from commercial invoices (ai_extract v2.1). field_confidence holds per-field confidence 0-1; raw_extract keeps citations.'
AS WITH x AS (
  SELECT pack_id, file_name, source_path,
    ai_extract(parsed, '{
      "invoice_number": {"type": "string", "description": "Invoice number or reference printed on the invoice"},
      "invoice_date":   {"type": "string", "description": "Invoice date, normalised to ISO format YYYY-MM-DD"},
      "seller_name":    {"type": "string", "description": "Seller / exporter / vendor / shipper legal name in English"},
      "seller_country": {"type": "enum", "labels": ["SG","MY","TH","VN","ID","PH","CN","JP","KR","IN","US","OTHER"], "description": "ISO-2 country of the seller"},
      "buyer_name":     {"type": "string", "description": "Buyer / importer / consignee / customer legal name"},
      "buyer_uen":      {"type": "string", "description": "Buyer UEN (Singapore business registration number)"},
      "currency":       {"type": "enum", "labels": ["USD","SGD","CNY","MYR","THB","EUR","OTHER"]},
      "incoterm":       {"type": "enum", "labels": ["FOB","CIF","CFR","EXW","DAP","DDP","OTHER"]},
      "port_of_loading":{"type": "string", "description": "Port of loading (city/port name only)"},
      "shipment_date":  {"type": "string", "description": "Shipment / ETD date, ISO format YYYY-MM-DD"},
      "total_amount":   {"type": "number", "description": "Invoice grand total amount, number only"},
      "line_items": {"type": "array", "items": {"type": "object", "properties": {
          "hs_code":     {"type": "string", "description": "HS / tariff code exactly as printed, e.g. 8504.40"},
          "description": {"type": "string", "description": "Goods description in English"},
          "quantity":    {"type": "number"},
          "unit":        {"type": "string"},
          "unit_price":  {"type": "number"},
          "amount":      {"type": "number"}}}}
    }', map('version', '2.1', 'enableConfidenceScores', 'true', 'enableCitations', 'true',
            'instructions', 'Customs trade permit supporting document. Copy company names, reference numbers and HS codes exactly as printed, character for character; never correct or standardise spelling. Normalise dates to YYYY-MM-DD. Documents may be bilingual English/Chinese; return English values.')) AS x
  FROM STREAM silver_documents
  WHERE doc_type = 'commercial_invoice'
)
SELECT pack_id, file_name, source_path,
  x:response:invoice_number:value::STRING   AS invoice_number,
  coalesce(try_to_date(x:response:invoice_date:value::STRING, 'yyyy-MM-dd'), try_to_date(x:response:invoice_date:value::STRING, 'dd-MM-yyyy'), try_to_date(x:response:invoice_date:value::STRING, 'dd/MM/yyyy'), try_to_date(x:response:invoice_date:value::STRING, 'd MMM yyyy'), try_to_date(x:response:invoice_date:value::STRING, 'MMMM d, yyyy'), try_to_date(x:response:invoice_date:value::STRING, 'yyyy年MM月dd日'))  AS invoice_date,
  x:response:seller_name:value::STRING      AS seller_name,
  x:response:seller_country:value::STRING   AS seller_country,
  x:response:buyer_name:value::STRING       AS buyer_name,
  x:response:buyer_uen:value::STRING        AS buyer_uen,
  x:response:currency:value::STRING         AS currency,
  x:response:incoterm:value::STRING         AS incoterm,
  x:response:port_of_loading:value::STRING  AS port_of_loading,
  coalesce(try_to_date(x:response:shipment_date:value::STRING, 'yyyy-MM-dd'), try_to_date(x:response:shipment_date:value::STRING, 'dd-MM-yyyy'), try_to_date(x:response:shipment_date:value::STRING, 'dd/MM/yyyy'), try_to_date(x:response:shipment_date:value::STRING, 'd MMM yyyy'), try_to_date(x:response:shipment_date:value::STRING, 'MMMM d, yyyy'), try_to_date(x:response:shipment_date:value::STRING, 'yyyy年MM月dd日')) AS shipment_date,
  x:response:total_amount:value::DOUBLE     AS total_amount,
  transform(CAST(x:response:line_items AS ARRAY<VARIANT>), li -> named_struct(
    'hs_code', li:hs_code:value::STRING, 'description', li:description:value::STRING,
    'quantity', li:quantity:value::DOUBLE, 'unit', li:unit:value::STRING,
    'unit_price', li:unit_price:value::DOUBLE, 'amount', li:amount:value::DOUBLE,
    'conf', least(li:hs_code:confidence_score::DOUBLE, li:quantity:confidence_score::DOUBLE, li:amount:confidence_score::DOUBLE)
  )) AS line_items,
  array(
    named_struct('field', 'invoice_number', 'conf', x:response:invoice_number:confidence_score::DOUBLE),
    named_struct('field', 'invoice_date',   'conf', x:response:invoice_date:confidence_score::DOUBLE),
    named_struct('field', 'seller_name',    'conf', x:response:seller_name:confidence_score::DOUBLE),
    named_struct('field', 'buyer_name',     'conf', x:response:buyer_name:confidence_score::DOUBLE),
    named_struct('field', 'currency',       'conf', x:response:currency:confidence_score::DOUBLE),
    named_struct('field', 'port_of_loading','conf', x:response:port_of_loading:confidence_score::DOUBLE),
    named_struct('field', 'shipment_date',  'conf', x:response:shipment_date:confidence_score::DOUBLE),
    named_struct('field', 'total_amount',   'conf', x:response:total_amount:confidence_score::DOUBLE)
  ) AS field_confidence,
  x:error_message::STRING AS extract_error,
  x AS raw_extract
FROM x;
