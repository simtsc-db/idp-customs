-- Reference: port of loading to country, for the direct consignment check.
CREATE OR REFRESH MATERIALIZED VIEW ref_ports
COMMENT 'Port of loading to ISO-2 country, used for the direct consignment check.'
AS SELECT lower(port_name) AS port_key, port_name, country_code
FROM read_files('/Volumes/${catalog}/${schema}/permit_packs/reference/ports.csv', format => 'csv', header => true);
