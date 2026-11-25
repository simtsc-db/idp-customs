-- Layer: bronze
-- Bronze: every trader document that lands in the inbox is parsed exactly once.
-- ai_parse_document (v2.0) handles PDFs and scanned images (OCR + layout).
-- AI figure descriptions are disabled ('') to keep cost per document low.

CREATE OR REFRESH MATERIALIZED VIEW ref_ports
COMMENT 'Port of loading to ISO-2 country, used for the direct consignment check.'
AS SELECT lower(port_name) AS port_key, port_name, country_code
FROM read_files('/Volumes/${catalog}/${schema}/permit_packs/reference/ports.csv', format => 'csv', header => true);
