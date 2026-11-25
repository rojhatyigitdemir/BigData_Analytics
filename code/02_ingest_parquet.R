# =============================================================================
# 02_ingest_parquet.R
# Convert the raw CSV (about 5 GB) to Parquet partitioned by year, using DuckDB.
#
# Why DuckDB + Parquet instead of reading the CSV into R?
#   * the CSV is parsed in parallel, in chunks, out of core: R memory stays flat
#   * Parquet is columnar and compressed: later queries read only needed columns
#   * partitioning by year lets queries on a time window skip whole files
# =============================================================================

source("code/00_config.R")
source("code/utils.R")
load_packages(c("DBI", "duckdb"))

stopifnot("Raw CSV not found. Run 01_download.R (or the synthetic generator)." =
            file.exists(RAW_CSV))

# --- Schema check before the long ingest ------------------------------------------
# Fails early, with a clear message, if the file is an Excel view or a filtered
# web export instead of the full CSV (those can lack the date columns).
con_chk <- connect_duckdb(":memory:")
cols <- DBI::dbGetQuery(con_chk, sprintf(
  "DESCRIBE SELECT * FROM read_csv('%s', header = true, all_varchar = true,
                                    quote = '\"', escape = '\"', sample_size = 2048)",
  RAW_CSV))$column_name
DBI::dbDisconnect(con_chk, shutdown = TRUE)
message("Columns found (", length(cols), "): ", paste(cols, collapse = " | "))
missing_cols <- setdiff(REQUIRED_COLUMNS, cols)
if (length(missing_cols) > 0) {
  stop("The raw file lacks required columns: ", paste(missing_cols, collapse = ", "),
       ".\nUse the full CSV from https://files.consumerfinance.gov/ccdb/complaints.csv.zip ",
       "(01_download.R). Do not use an Excel copy or a filtered export from the search page.")
}
write.csv(data.frame(column = cols, required = cols %in% REQUIRED_COLUMNS),
          file.path(DIR_TAB, "raw_columns.csv"), row.names = FALSE)

unlink(DIR_PARQUET, recursive = TRUE)
dir.create(DIR_PARQUET, recursive = TRUE, showWarnings = FALSE)

con <- connect_duckdb()
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

mem_before <- gc()[, 2]
run_sql_file(con, file.path(DIR_SQL, "01_ingest.sql"),
             list(RAW_CSV = RAW_CSV, PARQUET_DIR = DIR_PARQUET))
mem_after <- gc()[, 2]

# --- Quick checks ---------------------------------------------------------------
summary_tbl <- DBI::dbGetQuery(con, "
  SELECT year, COUNT(*) AS n, AVG(is_late) AS late_rate,
         MIN(date_received) AS first_date, MAX(date_received) AS last_date,
         AVG(CASE WHEN date_sent IS NULL THEN 1 ELSE 0 END) AS share_no_date_sent,
         MEDIAN(date_sent - date_received)  AS median_days_to_company
  FROM complaints GROUP BY year ORDER BY year;")
print(summary_tbl)
write.csv(summary_tbl, file.path(DIR_TAB, "complaints_by_year.csv"), row.names = FALSE)

csv_mb     <- file.size(RAW_CSV) / 1e6
parquet_mb <- sum(file.size(list.files(DIR_PARQUET, recursive = TRUE, full.names = TRUE))) / 1e6
message(sprintf("CSV: %.0f MB -> Parquet: %.0f MB (%.0f%% of original)",
                csv_mb, parquet_mb, 100 * parquet_mb / csv_mb))
message(sprintf("R memory change during ingest: %.1f MB", sum(mem_after - mem_before)))
write.csv(data.frame(csv_mb = csv_mb, parquet_mb = parquet_mb),
          file.path(DIR_TAB, "storage_size.csv"), row.names = FALSE)
