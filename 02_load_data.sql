-- =============================================================
-- 02_load_data.sql
-- Loads the CSVs in data/ into the tables created by 01_schema_ddl.sql.
-- Run AFTER 01_schema_ddl.sql and BEFORE 03_etl_transform.sql.
--
-- Run from the repository root with psql (\copy reads files on the client):
--     psql "<connection string>" -f sql/02_load_data.sql
--
-- The dimension CSVs carry a few more columns than the database tables
-- (and use slightly different names for some), so each file is read into a
-- staging table first and mapped column by column.
-- =============================================================

BEGIN;

-- ---------- dim_date ----------
\copy dim_date FROM 'data/dimensions/dim_date.csv' WITH (FORMAT csv, HEADER true)

-- ---------- dim_region ----------
CREATE TEMP TABLE stg_region (region_id INT, region_name TEXT, basin TEXT, province TEXT, country TEXT, regulatory_body TEXT);
\copy stg_region FROM 'data/dimensions/dim_region.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO dim_region (region_id, region_name, province, basin, regulatory_body)
SELECT region_id, region_name, province, basin, regulatory_body FROM stg_region;

-- ---------- dim_operator ----------
CREATE TEMP TABLE stg_operator (operator_id INT, operator_name TEXT, operator_type TEXT, licence_number TEXT, contact_email TEXT, province TEXT, is_active TEXT);
\copy stg_operator FROM 'data/dimensions/dim_operator.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO dim_operator (operator_id, operator_name, operator_type, country, province)
SELECT operator_id, operator_name, operator_type, 'Canada', province FROM stg_operator;

-- ---------- dim_product ----------
\copy dim_product FROM 'data/dimensions/dim_product.csv' WITH (FORMAT csv, HEADER true)

-- ---------- dim_well ----------
CREATE TEMP TABLE stg_well (well_id INT, well_name TEXT, well_type TEXT, well_status TEXT, spud_date TEXT, region_id INT, operator_id INT, licence_number TEXT, surface_lat NUMERIC, surface_lon NUMERIC);
\copy stg_well FROM 'data/dimensions/dim_well.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO dim_well (well_id, well_name, well_type, status, region_id, operator_id, licence_no, latitude, longitude)
SELECT well_id, well_name, well_type, well_status, region_id, operator_id, licence_number, surface_lat, surface_lon FROM stg_well;

-- ---------- fact_production (raw, dirty) ----------
\copy fact_production FROM 'data/fact_production_raw.csv' WITH (FORMAT csv, HEADER true)

COMMIT;

-- Sanity check: expect 1827 / 6 / 20 / 5 / 300 / 52200
SELECT (SELECT COUNT(*) FROM dim_date)       AS dim_date,
       (SELECT COUNT(*) FROM dim_region)     AS dim_region,
       (SELECT COUNT(*) FROM dim_operator)   AS dim_operator,
       (SELECT COUNT(*) FROM dim_product)    AS dim_product,
       (SELECT COUNT(*) FROM dim_well)       AS dim_well,
       (SELECT COUNT(*) FROM fact_production) AS fact_production;
