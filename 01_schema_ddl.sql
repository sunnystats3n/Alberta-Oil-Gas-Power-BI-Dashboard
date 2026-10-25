-- =============================================================
-- 01_schema_ddl.sql
-- Star schema for the Alberta Oil & Gas production dashboard.
-- Run FIRST, before loading data and before 03_etl_transform.sql.
--
-- Provenance: recovered from the Supabase migration history
-- (migration "rebuild_schema_v2"), i.e. the DDL that was actually
-- applied to the database. Content is unchanged from that migration.
-- =============================================================

CREATE TABLE dim_date (
    date_id        INTEGER      PRIMARY KEY,
    full_date      DATE         NOT NULL,
    year           SMALLINT     NOT NULL,
    quarter        SMALLINT     NOT NULL,
    month          SMALLINT     NOT NULL,
    month_name     VARCHAR(10)  NOT NULL,
    day            SMALLINT     NOT NULL,
    day_of_week    VARCHAR(10)  NOT NULL,
    week_of_year   SMALLINT     NOT NULL,
    is_weekend     BOOLEAN      NOT NULL,
    fiscal_year    SMALLINT     NOT NULL,
    fiscal_quarter SMALLINT     NOT NULL
);

CREATE TABLE dim_region (
    region_id       INTEGER     PRIMARY KEY,
    region_name     VARCHAR(50) NOT NULL,
    province        VARCHAR(30) NOT NULL DEFAULT 'Alberta',
    basin           VARCHAR(50),
    regulatory_body VARCHAR(100)
);

CREATE TABLE dim_operator (
    operator_id   INTEGER      PRIMARY KEY,
    operator_name VARCHAR(100) NOT NULL,
    operator_type VARCHAR(20)  NOT NULL,
    country       VARCHAR(50)  NOT NULL DEFAULT 'Canada',
    province      VARCHAR(30)  NOT NULL DEFAULT 'Alberta'
);

CREATE TABLE dim_product (
    product_id      INTEGER      PRIMARY KEY,
    product_name    VARCHAR(50)  NOT NULL,
    product_type    VARCHAR(20)  NOT NULL,
    unit_of_measure VARCHAR(10)  NOT NULL,
    benchmark_price NUMERIC(8,2)
);

CREATE TABLE dim_well (
    well_id     INTEGER      PRIMARY KEY,
    well_name   VARCHAR(30)  NOT NULL,
    well_type   VARCHAR(20)  NOT NULL,
    status      VARCHAR(20)  NOT NULL,
    region_id   INTEGER      NOT NULL REFERENCES dim_region(region_id),
    operator_id INTEGER      NOT NULL REFERENCES dim_operator(operator_id),
    licence_no  VARCHAR(30),
    latitude    NUMERIC(9,6),
    longitude   NUMERIC(9,6)
);

-- Raw (dirty) fact table: the ETL input.
CREATE TABLE fact_production (
    production_id   BIGINT        PRIMARY KEY,
    date_id         INTEGER       NOT NULL,
    well_id         INTEGER       NOT NULL,
    product_id      INTEGER       NOT NULL,
    operator_id     INTEGER       NOT NULL,
    region_id       INTEGER       NOT NULL,
    volume_produced NUMERIC(12,2),
    revenue         NUMERIC(15,2),
    cost_per_unit   NUMERIC(10,2),
    royalty_rate    NUMERIC(5,4),
    operating_cost  NUMERIC(15,2),
    net_revenue     NUMERIC(15,2),
    source_system   VARCHAR(50)
);

CREATE INDEX idx_fp_date_id     ON fact_production(date_id);
CREATE INDEX idx_fp_well_id     ON fact_production(well_id);
CREATE INDEX idx_fp_product_id  ON fact_production(product_id);
CREATE INDEX idx_fp_operator_id ON fact_production(operator_id);
CREATE INDEX idx_fp_region_id   ON fact_production(region_id);
CREATE INDEX idx_fp_source      ON fact_production(source_system);
