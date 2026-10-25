-- =============================================================
-- 03_etl_transform.sql
-- ETL Pipeline: Extract → Transform → Load
-- Raw dirty data in → clean reporting table out → Power BI connects here
-- Run AFTER 02_load_data.sql
-- =============================================================
-- PIPELINE OVERVIEW
-- ─────────────────
-- EXTRACT : fact_production          (raw, 52,200 rows, 11 error types)
-- TRANSFORM: CTEs below              (cleaning rules documented per step)
-- LOAD    : fact_production_clean    (Power BI connects to THIS table only)
-- =============================================================

-- ========================
-- STEP 0: CREATE THE CLEAN REPORTING TABLE
-- Power BI will import from this table, not from fact_production
-- ========================
DROP TABLE IF EXISTS fact_production_clean;

CREATE TABLE fact_production_clean (
    clean_id         BIGSERIAL    PRIMARY KEY,
    production_id    BIGINT       NOT NULL,       -- Original PK — preserved for traceability
    date_id          INTEGER      NOT NULL,
    well_id          INTEGER      NOT NULL,
    product_id       INTEGER      NOT NULL,
    operator_id      INTEGER      NOT NULL,
    region_id        INTEGER      NOT NULL,
    volume_produced  NUMERIC(12,2) NOT NULL,
    revenue          NUMERIC(15,2) NOT NULL,
    cost_per_unit    NUMERIC(10,2) NOT NULL,
    royalty_rate     NUMERIC(5,4)  NOT NULL,
    operating_cost   NUMERIC(15,2) NOT NULL,
    net_revenue      NUMERIC(15,2) NOT NULL,
    source_system    VARCHAR(50),
    etl_load_ts      TIMESTAMP     DEFAULT NOW()
);

COMMENT ON TABLE fact_production_clean IS
'ETL output — clean, validated, de-duplicated production records ready for Power BI. '
'Populated by 03_etl_transform.sql. Re-run the LOAD section to refresh after source data changes.';

CREATE INDEX idx_clean_date_id     ON fact_production_clean(date_id);
CREATE INDEX idx_clean_well_id     ON fact_production_clean(well_id);
CREATE INDEX idx_clean_product_id  ON fact_production_clean(product_id);
CREATE INDEX idx_clean_operator_id ON fact_production_clean(operator_id);
CREATE INDEX idx_clean_region_id   ON fact_production_clean(region_id);


-- ========================
-- STEP 1: EXTRACT
-- Count raw records and identify each issue before transforming
-- Run these SELECT statements to understand the raw data
-- ========================

-- Raw record count
-- SELECT COUNT(*) AS raw_records FROM fact_production;
-- Expected: ~52,800

-- Issue summary before transformation
-- SELECT
--     COUNT(*)                                              AS total_raw,
--     COUNT(*) FILTER (WHERE volume_produced IS NULL)       AS null_volumes,
--     COUNT(*) FILTER (WHERE revenue IS NULL)               AS null_revenues,
--     COUNT(*) FILTER (WHERE volume_produced < 0)           AS negative_volumes,
--     COUNT(*) FILTER (WHERE volume_produced > 50000)       AS extreme_volumes,
--     COUNT(*) FILTER (WHERE revenue = 0 AND volume_produced > 0) AS zero_rev_pos_vol,
--     COUNT(*) FILTER (WHERE date_id NOT IN (SELECT date_id FROM dim_date)) AS invalid_dates
-- FROM fact_production;


-- ========================
-- STEP 2: TRANSFORM
-- All cleaning logic lives in a single CTE chain.
-- Each CTE applies one documented rule.
-- ========================

-- ========================
-- STEP 3: LOAD
-- Insert the fully transformed, clean records into fact_production_clean
-- ========================

INSERT INTO fact_production_clean (
    production_id, date_id, well_id, product_id, operator_id, region_id,
    volume_produced, revenue, cost_per_unit, royalty_rate,
    operating_cost, net_revenue, source_system
)
WITH

-- ─────────────────────────────────────────────────────────────
-- T1: Remove rows with NULL in any critical measurement field
--     Rule: A production record with no volume or no revenue
--           cannot be reported — exclude from the clean layer.
-- ─────────────────────────────────────────────────────────────
step1_drop_nulls AS (
    SELECT *
    FROM fact_production
    WHERE volume_produced IS NOT NULL
      AND revenue         IS NOT NULL
      AND cost_per_unit   IS NOT NULL
      AND royalty_rate    IS NOT NULL
),

-- ─────────────────────────────────────────────────────────────
-- T2: Remove rows with invalid or future dates
--     Rule: date_id must exist in dim_date (valid calendar date
--           within 2020-01-01 to 2024-12-31).
-- ─────────────────────────────────────────────────────────────
step2_valid_dates AS (
    SELECT s.*
    FROM step1_drop_nulls s
    WHERE s.date_id IN (SELECT date_id FROM dim_date)
),

-- ─────────────────────────────────────────────────────────────
-- T3: Remove rows with orphaned dimension keys
--     Rule: well_id, operator_id, and region_id must each
--           exist in their respective dimension tables.
--           Orphaned keys indicate ETL mapping failures upstream.
-- ─────────────────────────────────────────────────────────────
step3_valid_keys AS (
    SELECT s.*
    FROM step2_valid_dates s
    WHERE EXISTS (SELECT 1 FROM dim_well     w WHERE w.well_id     = s.well_id    )
      AND EXISTS (SELECT 1 FROM dim_operator o WHERE o.operator_id = s.operator_id)
      AND EXISTS (SELECT 1 FROM dim_region   r WHERE r.region_id   = s.region_id  )
),

-- ─────────────────────────────────────────────────────────────
-- T4: Remove rows with negative or implausible volumes
--     Rule: volume_produced must be > 0 and within a plausible
--           operational range. Max realistic daily production:
--           ~9,000 BBL for liquids, ~9,000 MCF for gas.
--           Values above 50,000 are data entry errors (extra zeros).
-- ─────────────────────────────────────────────────────────────
step4_valid_volumes AS (
    SELECT s.*
    FROM step3_valid_keys s
    WHERE s.volume_produced  > 0
      AND s.volume_produced  <= 50000
),

-- ─────────────────────────────────────────────────────────────
-- T5: Fix revenue inconsistency — recalculate revenue where
--     revenue = 0 but volume and price are valid.
--     Rule: revenue = volume_produced × cost_per_unit.
--           A zero revenue with positive volume and a known price
--           is a calculation error, not a valid zero-revenue event.
-- ─────────────────────────────────────────────────────────────
step5_fix_revenue AS (
    SELECT
        production_id,
        date_id,
        well_id,
        product_id,
        operator_id,
        region_id,
        volume_produced,
        -- Recalculate revenue if it is zero with a valid volume and price
        CASE
            WHEN revenue = 0 AND volume_produced > 0 AND cost_per_unit > 0
            THEN ROUND((volume_produced * cost_per_unit)::NUMERIC, 2)
            ELSE revenue
        END                                                    AS revenue,
        cost_per_unit,
        royalty_rate,
        -- Recalculate derived cost fields to stay consistent with corrected revenue
        CASE
            WHEN revenue = 0 AND volume_produced > 0 AND cost_per_unit > 0
            THEN ROUND((volume_produced * cost_per_unit * 0.35)::NUMERIC, 2)
            ELSE operating_cost
        END                                                    AS operating_cost,
        CASE
            WHEN revenue = 0 AND volume_produced > 0 AND cost_per_unit > 0
            THEN ROUND((volume_produced * cost_per_unit * 0.65)::NUMERIC, 2)
            ELSE net_revenue
        END                                                    AS net_revenue,
        source_system
    FROM step4_valid_volumes
),

-- ─────────────────────────────────────────────────────────────
-- T6: Fix region mismatch — align fact region_id with dim_well
--     Rule: The region a well belongs to (dim_well.region_id)
--           is the authoritative source. If the fact row disagrees,
--           the well dimension wins — ETL sourced it from a stale lookup.
-- ─────────────────────────────────────────────────────────────
step6_fix_region AS (
    SELECT
        s.production_id,
        s.date_id,
        s.well_id,
        s.product_id,
        s.operator_id,
        COALESCE(w.region_id, s.region_id)  AS region_id,   -- Trust dim_well; fall back to fact only if well not found
        s.volume_produced,
        s.revenue,
        s.cost_per_unit,
        s.royalty_rate,
        s.operating_cost,
        s.net_revenue,
        s.source_system
    FROM step5_fix_revenue s
    LEFT JOIN dim_well w ON s.well_id = w.well_id
),

-- ─────────────────────────────────────────────────────────────
-- T7: Align operator_id with dim_well (same logic as region)
--     Rule: dim_well.operator_id is authoritative.
--           Fact rows sometimes carry an operator from a different
--           source system snapshot than the current dimension.
-- ─────────────────────────────────────────────────────────────
step7_fix_operator AS (
    SELECT
        s.production_id,
        s.date_id,
        s.well_id,
        s.product_id,
        COALESCE(w.operator_id, s.operator_id) AS operator_id,
        s.region_id,
        s.volume_produced,
        s.revenue,
        s.cost_per_unit,
        s.royalty_rate,
        s.operating_cost,
        s.net_revenue,
        s.source_system
    FROM step6_fix_region s
    LEFT JOIN dim_well w ON s.well_id = w.well_id
),

-- ─────────────────────────────────────────────────────────────
-- T8: Remove logical duplicates
--     Rule: A (well_id, date_id, product_id) combination should
--           appear only once. Where duplicates exist (from double
--           submission across source systems), keep the record with
--           the highest production_id (most recently loaded).
-- ─────────────────────────────────────────────────────────────
step8_deduplicate AS (
    SELECT DISTINCT ON (well_id, date_id, product_id)
        production_id,
        date_id,
        well_id,
        product_id,
        operator_id,
        region_id,
        volume_produced,
        revenue,
        cost_per_unit,
        royalty_rate,
        operating_cost,
        net_revenue,
        source_system
    FROM step7_fix_operator
    ORDER BY well_id, date_id, product_id, production_id DESC
),

-- ─────────────────────────────────────────────────────────────
-- T9: Final assertion — ensure all derived financials are consistent
--     Rule: operating_cost + net_revenue must equal revenue (within $0.02 rounding).
--           Any remaining inconsistency indicates a source system calculation error;
--           recalculate from first principles.
-- ─────────────────────────────────────────────────────────────
step9_assert_financials AS (
    SELECT
        production_id,
        date_id,
        well_id,
        product_id,
        operator_id,
        region_id,
        volume_produced,
        revenue,
        cost_per_unit,
        royalty_rate,
        -- Recalculate if operating_cost + net_revenue deviates from revenue by more than $0.02
        CASE
            WHEN ABS((operating_cost + net_revenue) - revenue) > 0.02
            THEN ROUND((revenue * 0.35)::NUMERIC, 2)
            ELSE operating_cost
        END  AS operating_cost,
        CASE
            WHEN ABS((operating_cost + net_revenue) - revenue) > 0.02
            THEN ROUND((revenue * 0.65)::NUMERIC, 2)
            ELSE net_revenue
        END  AS net_revenue,
        source_system
    FROM step8_deduplicate
    WHERE revenue > 0
      AND volume_produced > 0
)

-- ─────────────────────────────────────────────────────────────
-- LOAD: Insert all fully transformed, clean records
-- ─────────────────────────────────────────────────────────────
SELECT
    production_id,
    date_id,
    well_id,
    product_id,
    operator_id,
    region_id,
    volume_produced,
    revenue,
    cost_per_unit,
    royalty_rate,
    operating_cost,
    net_revenue,
    source_system
FROM step9_assert_financials;


-- ========================
-- STEP 4: VALIDATE LOAD
-- Run these after the INSERT to confirm the ETL completed correctly
-- ========================

-- Record count comparison (uncomment to run)
-- SELECT
--     'Raw records'           AS stage, COUNT(*) AS row_count FROM fact_production
-- UNION ALL
-- SELECT 'After T1 drop nulls',          COUNT(*) FROM fact_production
--     WHERE volume_produced IS NOT NULL AND revenue IS NOT NULL
--       AND cost_per_unit IS NOT NULL AND royalty_rate IS NOT NULL
-- UNION ALL
-- SELECT 'Clean records loaded',         COUNT(*) FROM fact_production_clean;

-- Financial consistency check (should return 0 rows)
-- SELECT COUNT(*) AS financial_inconsistencies
-- FROM fact_production_clean
-- WHERE ABS((operating_cost + net_revenue) - revenue) > 0.02;

-- Referential integrity check (should return 0 rows for each)
-- SELECT 'Orphaned well_id' AS check_name, COUNT(*) AS violations
-- FROM fact_production_clean c
-- WHERE NOT EXISTS (SELECT 1 FROM dim_well w WHERE w.well_id = c.well_id)
-- UNION ALL
-- SELECT 'Orphaned operator_id', COUNT(*)
-- FROM fact_production_clean c
-- WHERE NOT EXISTS (SELECT 1 FROM dim_operator o WHERE o.operator_id = c.operator_id)
-- UNION ALL
-- SELECT 'Orphaned region_id', COUNT(*)
-- FROM fact_production_clean c
-- WHERE NOT EXISTS (SELECT 1 FROM dim_region r WHERE r.region_id = c.region_id);

-- Duplicate check (should return 0 rows)
-- SELECT well_id, date_id, product_id, COUNT(*) AS cnt
-- FROM fact_production_clean
-- GROUP BY well_id, date_id, product_id
-- HAVING COUNT(*) > 1;


-- ========================
-- ANALYTICAL VIEWS
-- Power BI can connect to these instead of the base table
-- for pre-aggregated data (faster refresh on large datasets)
-- ========================

-- Monthly summary (feeds line charts and trend visuals)
CREATE OR REPLACE VIEW vw_monthly_summary AS
SELECT
    d.year,
    d.quarter,
    d.month,
    d.month_name,
    d.fiscal_year,
    d.fiscal_quarter,
    p.product_name,
    p.product_type,
    p.unit_of_measure,
    r.region_name,
    r.basin,
    o.operator_name,
    o.operator_type,
    w.well_type,
    COUNT(c.clean_id)                                                      AS record_count,
    COUNT(DISTINCT c.well_id)                                              AS active_wells,
    ROUND(SUM(c.volume_produced)::NUMERIC,  2)                            AS total_volume,
    ROUND(SUM(c.revenue)::NUMERIC,          2)                            AS total_revenue,
    ROUND(SUM(c.operating_cost)::NUMERIC,   2)                            AS total_op_cost,
    ROUND(SUM(c.net_revenue)::NUMERIC,      2)                            AS total_net_revenue,
    ROUND(AVG(c.cost_per_unit)::NUMERIC,    2)                            AS avg_price_per_unit,
    ROUND(AVG(c.royalty_rate)::NUMERIC,     4)                            AS avg_royalty_rate,
    ROUND(SUM(c.net_revenue) /
          NULLIF(SUM(c.revenue), 0) * 100,  2)                            AS net_margin_pct,
    ROUND(SUM(c.revenue) /
          NULLIF(SUM(c.volume_produced), 0), 2)                           AS revenue_per_unit
FROM fact_production_clean c
JOIN dim_date     d ON c.date_id     = d.date_id
JOIN dim_product  p ON c.product_id  = p.product_id
JOIN dim_region   r ON c.region_id   = r.region_id
JOIN dim_operator o ON c.operator_id = o.operator_id
JOIN dim_well     w ON c.well_id     = w.well_id
GROUP BY
    d.year, d.quarter, d.month, d.month_name, d.fiscal_year, d.fiscal_quarter,
    p.product_name, p.product_type, p.unit_of_measure,
    r.region_name, r.basin, o.operator_name, o.operator_type, w.well_type;

-- Well performance with MoM growth (feeds well-level analytics)
CREATE OR REPLACE VIEW vw_well_performance AS
WITH monthly AS (
    SELECT
        c.well_id,
        w.well_name,
        w.well_type,
        r.region_name,
        o.operator_name,
        p.product_name,
        d.year,
        d.month,
        d.month_name,
        ROUND(SUM(c.revenue)::NUMERIC,         2) AS monthly_revenue,
        ROUND(SUM(c.volume_produced)::NUMERIC, 2) AS monthly_volume,
        ROUND(SUM(c.net_revenue)::NUMERIC,     2) AS monthly_net_revenue
    FROM fact_production_clean c
    JOIN dim_well     w ON c.well_id     = w.well_id
    JOIN dim_date     d ON c.date_id     = d.date_id
    JOIN dim_region   r ON c.region_id   = r.region_id
    JOIN dim_operator o ON c.operator_id = o.operator_id
    JOIN dim_product  p ON c.product_id  = p.product_id
    GROUP BY c.well_id, w.well_name, w.well_type, r.region_name,
             o.operator_name, p.product_name, d.year, d.month, d.month_name
)
SELECT
    *,
    LAG(monthly_revenue) OVER (PARTITION BY well_id, product_name ORDER BY year, month) AS prev_month_revenue,
    ROUND(
        (monthly_revenue - LAG(monthly_revenue) OVER (PARTITION BY well_id, product_name ORDER BY year, month))
        / NULLIF(LAG(monthly_revenue) OVER (PARTITION BY well_id, product_name ORDER BY year, month), 0)
        * 100, 2
    )                                                                      AS mom_revenue_growth_pct,
    SUM(monthly_revenue) OVER (
        PARTITION BY well_id, product_name
        ORDER BY year, month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                                      AS cumulative_revenue,
    RANK() OVER (PARTITION BY year, month ORDER BY monthly_revenue DESC)   AS revenue_rank
FROM monthly;

-- YoY comparison (feeds waterfall and year comparison visuals)
CREATE OR REPLACE VIEW vw_yoy_comparison AS
WITH annual AS (
    SELECT
        d.year,
        p.product_name,
        r.region_name,
        ROUND(SUM(c.volume_produced)::NUMERIC, 2) AS total_volume,
        ROUND(SUM(c.revenue)::NUMERIC,         2) AS total_revenue,
        ROUND(SUM(c.net_revenue)::NUMERIC,     2) AS total_net_revenue,
        COUNT(DISTINCT c.well_id)                  AS active_wells
    FROM fact_production_clean c
    JOIN dim_date    d ON c.date_id    = d.date_id
    JOIN dim_product p ON c.product_id = p.product_id
    JOIN dim_region  r ON c.region_id  = r.region_id
    GROUP BY d.year, p.product_name, r.region_name
)
SELECT
    year, product_name, region_name,
    total_volume, total_revenue, total_net_revenue, active_wells,
    LAG(total_volume)  OVER (PARTITION BY product_name, region_name ORDER BY year) AS prev_year_volume,
    LAG(total_revenue) OVER (PARTITION BY product_name, region_name ORDER BY year) AS prev_year_revenue,
    ROUND(
        (total_volume - LAG(total_volume) OVER (PARTITION BY product_name, region_name ORDER BY year))
        / NULLIF(LAG(total_volume) OVER (PARTITION BY product_name, region_name ORDER BY year), 0)
        * 100, 2
    )                                                                              AS yoy_volume_growth_pct,
    ROUND(
        (total_revenue - LAG(total_revenue) OVER (PARTITION BY product_name, region_name ORDER BY year))
        / NULLIF(LAG(total_revenue) OVER (PARTITION BY product_name, region_name ORDER BY year), 0)
        * 100, 2
    )                                                                              AS yoy_revenue_growth_pct
FROM annual;

-- Operator scorecard (feeds operator ranking visuals)
CREATE OR REPLACE VIEW vw_operator_scorecard AS
SELECT
    o.operator_name,
    o.operator_type,
    d.year,
    r.region_name,
    COUNT(DISTINCT c.well_id)                                              AS active_wells,
    ROUND(SUM(c.volume_produced)::NUMERIC,    2)                          AS total_volume,
    ROUND(SUM(c.revenue)::NUMERIC,            2)                          AS total_revenue,
    ROUND(SUM(c.net_revenue)::NUMERIC,        2)                          AS total_net_revenue,
    ROUND(AVG(c.cost_per_unit)::NUMERIC,      2)                          AS avg_unit_price,
    ROUND(SUM(c.net_revenue) /
          NULLIF(SUM(c.revenue), 0) * 100,    2)                          AS net_margin_pct,
    RANK() OVER (PARTITION BY d.year ORDER BY SUM(c.revenue) DESC)        AS revenue_rank
FROM fact_production_clean c
JOIN dim_operator o ON c.operator_id = o.operator_id
JOIN dim_date     d ON c.date_id     = d.date_id
JOIN dim_region   r ON c.region_id   = r.region_id
GROUP BY o.operator_name, o.operator_type, d.year, r.region_name;

-- ETL record count summary (for your resume / presentation)
CREATE OR REPLACE VIEW vw_etl_summary AS
SELECT
    (SELECT COUNT(*) FROM fact_production)       AS raw_records_extracted,
    (SELECT COUNT(*) FROM fact_production_clean) AS clean_records_loaded,
    (SELECT COUNT(*) FROM fact_production)
        - (SELECT COUNT(*) FROM fact_production_clean) AS records_removed_by_etl,
    ROUND(
        (SELECT COUNT(*) FROM fact_production_clean)::NUMERIC
        / NULLIF((SELECT COUNT(*) FROM fact_production), 0) * 100,
    1)                                           AS pct_records_passed,
    NOW()                                        AS etl_run_timestamp;
