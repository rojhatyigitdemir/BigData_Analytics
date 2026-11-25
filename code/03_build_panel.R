# =============================================================================
# 03_build_panel.R
# Build the firm x month early-warning panel from the Parquet files.
# All heavy work (joins, aggregation, rolling windows over millions of rows)
# runs inside DuckDB; only the final panel is written to disk.
# Output: data/agg/firm_month_panel.parquet
# =============================================================================

source("code/00_config.R")
source("code/utils.R")
load_packages(c("DBI", "duckdb"))

con <- connect_duckdb()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

# the 'complaints' view from 02_ingest_parquet.R lives in the DuckDB file
stopifnot("Run 02_ingest_parquet.R first." =
            "complaints" %in% DBI::dbListTables(con))

run_sql_file(con, file.path(DIR_SQL, "02_firm_month_panel.sql"),
             c(list(PANEL_PARQUET = PANEL_PARQUET), PARAMS))

# --- Panel summary -------------------------------------------------------------
smry <- DBI::dbGetQuery(con, sprintf("
  SELECT COUNT(*)                                   AS rows,
         COUNT(DISTINCT company)                    AS firms,
         MIN(month)                                 AS first_month,
         MAX(month)                                 AS last_month,
         SUM(CASE WHEN has_outcome THEN 1 ELSE 0 END) AS rows_with_outcome,
         AVG(deteriorate)                           AS event_rate
  FROM read_parquet('%s');", PANEL_PARQUET))
print(smry)
write.csv(smry, file.path(DIR_TAB, "panel_summary.csv"), row.names = FALSE)

events_by_year <- DBI::dbGetQuery(con, sprintf("
  SELECT year, COUNT(*) AS firm_months, SUM(deteriorate) AS events,
         AVG(deteriorate) AS event_rate, AVG(late_past12) AS mean_late_rate
  FROM read_parquet('%s') WHERE has_outcome
  GROUP BY year ORDER BY year;", PANEL_PARQUET))
print(events_by_year)
write.csv(events_by_year, file.path(DIR_TAB, "panel_events_by_year.csv"), row.names = FALSE)
