# Alberta Oil & Gas Production Dashboard

A three-page Power BI report built on a star schema of simulated Alberta upstream oil and gas production data (2020-2024), fed by a SQL ETL pipeline that cleans a deliberately dirty raw table before it reaches the model.

> **All data is simulated.** Wells, operators, volumes and financials are synthetic and generated in Python. Nothing here represents a real company's production or results.

**Stack:** PostgreSQL (Supabase) for the raw and clean fact tables, SQL for the ETL and reporting views, Power BI (PBIP / TMDL project) for the semantic model, DAX measures and report pages.

## Dashboard pages

![Executive Overview](docs/images/01-executive-overview.png)
*Executive Overview*

![Production Deep Dive](docs/images/02-production-deep-dive.png)
*Production Deep Dive*

![Financial & Time Intelligence](docs/images/03-financial-time-intelligence.png)
*Financial & Time Intelligence*

Screenshots come from Power BI's PDF export, so scrollable visuals (the monthly revenue line, the matrix, the top-10 bar) show only the first screenful.

| Page | What it answers |
|---|---|
| **Executive Overview** | How much did we produce and earn, and where did it come from? Five KPI cards (revenue, volume, operating margin, YoY revenue growth, active wells), a monthly revenue trend, revenue by product and by region, annual volume by product, and slicers for year, region, product and operator type. |
| **Production Deep Dive** | Which operators and wells drive production? Operator scatter (average volume per well vs revenue per unit, sized by active wells), top 10 wells by revenue, a month-by-year volume matrix, volume by well type and product, and revenue trend by region as small multiples. |
| **Financial & Time Intelligence** | How are revenue and costs moving over time? Revenue waterfall by year and product, revenue vs operating cost by month, a year-over-year table, revenue per unit by month and year, and revenue by operator and year. |

## Data

| File | Rows | Description |
|---|---|---|
| `data/dimensions/dim_*.csv` | 1,827 / 6 / 20 / 5 / 300 | Date, region, operator, product and well dimensions. **Power BI reads these directly.** |
| `data/fact_production_raw.csv` | 52,200 | Raw, deliberately dirty fact table (the ETL input) |
| `data/fact_production_clean.csv` | 38,678 | Output of `sql/03_etl_transform.sql` on the raw file, for inspection |

`scripts/generate_fact_data.py` rebuilds the raw file (fixed seed, needs `pandas` and `numpy`). It is a re-creation of the original simulation, calibrated to the original database: 210 active wells, two products per well, fixed benchmark prices, 52,200 raw rows, and the same families of injected errors (NULLs, negative and extreme volumes, zero revenue, about 12,000 duplicates, region/operator mismatches against `dim_well`). Because it is a re-creation, totals are close to, but not identical with, the screenshots (about $4.17bn revenue and 99.4M units here, against $4.47bn and 100.2M units in the original database).

## Data pipeline

```
fact_production  (raw, 52,200 rows, ~11 injected error types)
        |
        |  sql/03_etl_transform.sql   (9 documented cleaning rules, T1-T9)
        v
fact_production_clean  (74.1% retained: 38,678 rows from the included CSV)  --->  Power BI
```

The ETL keeps every cleaning rule in one readable CTE chain:

| Rule | What it does |
|---|---|
| T1 | Drop rows with NULL volume, revenue, cost per unit or royalty rate |
| T2 | Drop rows whose `date_id` is not in `dim_date` (valid range 2020-01-01 to 2024-12-31) |
| T3 | Drop rows with orphaned `well_id`, `operator_id` or `region_id` |
| T4 | Drop non-positive volumes and implausible volumes above 50,000 |
| T5 | Recalculate revenue (and dependent cost fields) where revenue is 0 but volume and price are valid |
| T6 | Align `region_id` with `dim_well` (the well dimension is authoritative) |
| T7 | Align `operator_id` with `dim_well` |
| T8 | De-duplicate on (well, date, product), keeping the highest `production_id` |
| T9 | Final assertion: operating cost + net revenue must equal revenue within $0.02, otherwise recompute |

The same file also defines five reporting views (`vw_monthly_summary`, `vw_well_performance`, `vw_yoy_comparison`, `vw_operator_scorecard`, `vw_etl_summary`) and commented-out validation queries for row counts, referential integrity and duplicates.

## Semantic model

Star schema with `fact_production_clean` at the centre, joined many-to-one to `dim_date`, `dim_region`, `dim_operator`, `dim_product` and `dim_well`. There are no dimension-to-dimension relationships.

A hidden `_Measures` table holds 51 DAX measures, grouped roughly as:

- **Core totals:** volume, revenue, operating cost, net revenue, royalty expense, wells, operators
- **Ratios:** operating margin %, revenue per unit, average revenue and volume per well, cost recovery ratio
- **Time intelligence:** month-over-month, year-over-year, year-to-date and prior-year comparisons for revenue, volume and net revenue
- **Data quality:** null, negative, extreme and zero-revenue counts, flagged-record totals and a data quality score
- **Display helpers:** formatted revenue and volume strings, selected year / region / product labels

**Operating Margin %** is defined as `(Total Revenue - Total Operating Cost) / Total Revenue`. The **YoY Revenue Growth %** card on the Executive Overview carries a visual-level filter for 2024, so it shows 2024 vs 2023 rather than an aggregate across all years, which would be misleading.

## Known data caveats

These are properties of the simulated data, not bugs in the report:

1. **Margin is constant by design.** The ETL recalculates operating cost as 35% of revenue and net revenue as 65% (rules T5 and T9), and the dashboard's overall operating margin is exactly 65.00%. A chart of margin over time or by operator would be a flat line, so the operator scatter and the monthly trend on page 3 plot **revenue per unit** instead. In this data `cost_per_unit` equals the product's fixed price, so revenue per unit only moves with **product mix**, not with pricing or operating performance.
2. **Dimension sources differ.** Power BI loads the five dimension tables from the CSVs in `data/dimensions/` and only the fact table from PostgreSQL. In the original author's database, operator names and well-type assignments differed from these CSVs, and the CSV headers use different column names from the DDL. `sql/02_load_data.sql` maps the CSVs onto the DDL, so a database built from this repo is consistent with the dashboard.
3. **The fact data in this repo is a re-creation** (see *Data* above), so numbers differ slightly from the screenshots.
4. **Operating margin of 65% and a flat revenue-per-unit pattern are outputs of the simulation, not business findings.** The dashboard demonstrates modelling, DAX and layout; it does not support conclusions about real operators.

## Repository layout

```
.
|-- powerbi/
|   |-- Alberta_Oil_&_Gas Dashboard.pbip          open this in Power BI Desktop
|   |-- Alberta_Oil_&_Gas Dashboard.Report/       report pages and visuals (PBIR)
|   `-- Alberta_Oil_&_Gas Dashboard.SemanticModel/ tables, relationships, measures (TMDL)
|-- sql/
|   |-- 01_schema_ddl.sql                         tables and indexes
|   |-- 02_load_data.sql                          loads the CSVs (psql \copy)
|   `-- 03_etl_transform.sql                      ETL pipeline + reporting views
|-- scripts/
|   `-- generate_fact_data.py                     rebuilds data/fact_production_raw.csv
|-- data/
|   |-- dimensions/                               dim_date, dim_region, dim_operator, dim_product, dim_well
|   |-- fact_production_raw.csv                   ETL input
|   `-- fact_production_clean.csv                 ETL output
`-- docs/images/                                  dashboard screenshots
```

## Setup

The model has two kinds of data source, and both need repointing on a new machine:

1. **Dimension CSVs.** Five queries read from an absolute path on the original author's machine (`C:\Users\sunny\Downloads\Alberta_Oil_&_Gas_Analytics\`). In Power BI Desktop choose *Transform data*, open each `dim_*` query, edit the `Source` step and point it at the `data/dimensions/` folder of your clone. Alternatively, find-and-replace the path in the five `dim_*.tmdl` files under `SemanticModel/definition/tables/`.
2. **PostgreSQL fact table.** `fact_production_clean` and `vw_etl_summary` read from the original author's Supabase host. This repo contains **no credentials**: Power BI stores them in your local credential store, not in the project files. To use your own database, from the repo root:

   ```bash
   psql "<your connection string>" -f sql/01_schema_ddl.sql
   psql "<your connection string>" -f sql/02_load_data.sql    # loads the CSVs
   psql "<your connection string>" -f sql/03_etl_transform.sql # builds fact_production_clean and the views
   ```

   Then change the server and database in the `Source` step of `fact_production_clean` and `vw_etl_summary` (*Transform data*, or the matching `.tmdl` files) and sign in when prompted. Local PostgreSQL 14+ works as well as Supabase.

Optional: `python scripts/generate_fact_data.py` regenerates the raw CSV before step 2.

## Rebuilding the report from source

The report is stored as plain text (PBIR JSON for pages and visuals, TMDL for the model), so changes show up as readable diffs. Commit changes from the `powerbi/` folder only; Power BI's local cache and settings files are excluded by `.gitignore`.
