-- Silver: document type (ai_classify) and plain text.
CREATE OR REFRESH STREAMING TABLE silver_documents (
  CONSTRAINT parsed_without_error EXPECT (parse_error IS NULL),
  CONSTRAINT recognised_document_type EXPECT (doc_type IN ('commercial_invoice', 'packing_list', 'certificate_of_origin')),
  CONSTRAINT has_pack_id EXPECT (pack_id IS NOT NULL AND pack_id <> '') ON VIOLATION DROP ROW
)
COMMENT 'Parsed documents with document type (ai_classify) and plain text for display.'
AS SELECT
  pack_id, file_name, file_type, source_path, received_at,
  parsed,
  ai_classify(
    parsed,
    '{"commercial_invoice": "Commercial, tax or proforma invoice listing goods, prices and amounts due",
      "packing_list": "Packing list with quantities, packages and weights, no prices",
      "certificate_of_origin": "Certificate of Origin issued under a free trade agreement (Form D, CSFTA, RCEP)",
      "other": "Any other document"}',
    map('version', '2.0')
  ):response[0]::STRING                                                         AS doc_type,
  concat_ws('\n', transform(CAST(parsed:document:elements AS ARRAY<VARIANT>), e -> e:content::STRING)) AS doc_text,
  parsed:error_status                                                           AS parse_error
FROM STREAM bronze_documents;
