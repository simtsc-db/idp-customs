-- Bronze: parse each trader document once (ai_parse_document v2: OCR + layout).
CREATE OR REFRESH STREAMING TABLE bronze_documents
COMMENT 'One row per trader document received (PDF or scanned image), with the ai_parse_document v2.0 output. Source: UC volume permit_packs/inbox/<pack_id>/.'
AS SELECT
  regexp_extract(path, '(PP-[0-9]{4})', 1)              AS pack_id,
  regexp_extract(path, '[^/]+$', 0)                     AS file_name,
  lower(regexp_extract(path, '\\.([A-Za-z]+)$', 1))     AS file_type,
  path                                                  AS source_path,
  length(content)                                       AS file_bytes,
  modificationTime                                      AS received_at,
  ai_parse_document(content, map('version', '2.0', 'descriptionElementTypes', '')) AS parsed,
  current_timestamp()                                   AS parsed_at
FROM STREAM read_files(
  '/Volumes/${catalog}/${schema}/permit_packs/inbox/',
  format => 'binaryFile',
  recursiveFileLookup => true,
  pathGlobFilter => '*.{pdf,png,jpg,jpeg,tif,tiff}'
);

-- Governed reference data owned by the Trade Division (not hard-coded in logic)
