-- =============================================================================
-- 01_ingest.sql
-- Stream the raw CFPB CSV into Parquet, partitioned by year.
-- DuckDB reads the CSV in parallel chunks; nothing is loaded into R.
-- Columns are selected by name, so the script works with both the 18-column
-- public export and reduced exports. All columns are first read as text,
-- then typed explicitly (robust to mixed date formats).
-- Placeholders: {{RAW_CSV}}, {{PARQUET_DIR}}
-- =============================================================================

COPY (
  WITH raw AS (
    SELECT *
    FROM read_csv('{{RAW_CSV}}',
                  header = true, all_varchar = true,
                  quote = '"', escape = '"', max_line_size = 10000000)
  ),
  typed AS (
    SELECT
      COALESCE(TRY_CAST("Date received" AS DATE),
               CAST(TRY_STRPTIME("Date received", '%m/%d/%Y') AS DATE))      AS date_received,
      COALESCE(TRY_CAST("Date sent to company" AS DATE),
               CAST(TRY_STRPTIME("Date sent to company", '%m/%d/%Y') AS DATE)) AS date_sent,
      NULLIF(TRIM("Product"), '')                      AS product,
      NULLIF(TRIM("Sub-product"), '')                  AS sub_product,
      NULLIF(TRIM("Issue"), '')                        AS issue,
      NULLIF(TRIM("Sub-issue"), '')                    AS sub_issue,
      NULLIF(TRIM("Company"), '')                      AS company,
      NULLIF(TRIM("State"), '')                        AS state,
      COALESCE(NULLIF(TRIM("Tags"), ''), 'None')       AS tags,
      NULLIF(TRIM("Submitted via"), '')                AS submitted_via,
      -- kept for descriptive checks only, NEVER used as a model feature (leakage)
      NULLIF(TRIM("Company response to consumer"), '') AS company_response,
      NULLIF(TRIM("Timely response?"), '')             AS timely_response,
      TRY_CAST("Complaint ID" AS BIGINT)               AS complaint_id
    FROM raw
  )
  SELECT *,
         CASE WHEN timely_response = 'No' THEN 1 ELSE 0 END AS is_late,
         YEAR(date_received)                               AS year
  FROM typed
  WHERE date_received IS NOT NULL
    AND company IS NOT NULL
    AND timely_response IN ('Yes', 'No')
) TO '{{PARQUET_DIR}}'
  (FORMAT parquet, PARTITION_BY (year), COMPRESSION zstd, OVERWRITE_OR_IGNORE true);

-- A view over the Parquet files; later queries read only the columns they use.
CREATE OR REPLACE VIEW complaints AS
SELECT * FROM read_parquet('{{PARQUET_DIR}}/**/*.parquet', hive_partitioning = true);
