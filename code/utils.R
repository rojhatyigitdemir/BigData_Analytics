# =============================================================================
# utils.R
# Shared helpers: DuckDB connection, parameterised SQL files, timing log,
# and evaluation metrics for rare-event ranking.
# =============================================================================

# --- DuckDB -------------------------------------------------------------------

#' Open a connection to the project DuckDB database file.
#' DuckDB is an in-process columnar engine: it queries CSV/Parquet files
#' out of core, so the raw data never has to fit into R's memory.
connect_duckdb <- function(path = DUCKDB_FILE, threads = NULL) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = path)
  if (!is.null(threads)) DBI::dbExecute(con, sprintf("SET threads = %d;", threads))
  con
}

#' Read a .sql file, replace {{PLACEHOLDER}} tokens with values from `params`,
#' and split it into individual statements.
render_sql <- function(file, params = list()) {
  sql <- paste(readLines(file, warn = FALSE), collapse = "\n")
  for (key in names(params)) {
    sql <- gsub(sprintf("{{%s}}", key), as.character(params[[key]]), sql, fixed = TRUE)
  }
  left <- regmatches(sql, gregexpr("\\{\\{[A-Z_0-9]+\\}\\}", sql))[[1]]
  if (length(left) > 0) stop("Unfilled SQL parameters: ", paste(unique(left), collapse = ", "))
  # remove line comments, then split on semicolons at the end of a line
  sql <- gsub("--[^\n]*", "", sql)
  stmts <- trimws(strsplit(sql, ";[[:space:]]*(\n|$)")[[1]])
  stmts[nchar(stmts) > 0]
}

#' Execute every statement of a parameterised SQL file and log the run time.
run_sql_file <- function(con, file, params = list()) {
  stmts <- render_sql(file, params)
  secs <- system.time(for (s in stmts) DBI::dbExecute(con, s))[["elapsed"]]
  log_timing(basename(file), secs)
  invisible(secs)
}

# --- Timing log (feeds the performance table in the report) -------------------

log_timing <- function(step, seconds, file = file.path(DIR_TAB, "timings.csv")) {
  row <- data.frame(step = step, seconds = round(seconds, 2),
                    synthetic = USE_SYNTHETIC, run_at = format(Sys.time()))
  write.table(row, file, sep = ",", row.names = FALSE,
              col.names = !file.exists(file), append = file.exists(file))
  message(sprintf("[timing] %-28s %8.2f s", step, seconds))
}

# --- Panel loading ------------------------------------------------------------

#' Load the firm-month panel written by 03_build_panel.R.
#' The panel is small (thousands of rows), so it is read into memory.
load_panel <- function(path = PANEL_PARQUET) {
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  df <- DBI::dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", path))
  df$month <- as.Date(df$month)
  df
}

# --- Ranking metrics for rare events -----------------------------------------

#' Average precision (area under the precision-recall curve).
average_precision <- function(score, label) {
  ord <- order(score, decreasing = TRUE)
  y <- label[ord]
  if (sum(y) == 0) return(NA_real_)
  precision_at_hit <- cumsum(y)[y == 1] / which(y == 1)
  mean(precision_at_hit)
}

#' ROC-AUC via the rank-sum (Mann-Whitney) formula.
roc_auc <- function(score, label) {
  n1 <- sum(label == 1); n0 <- sum(label == 0)
  if (n1 == 0 || n0 == 0) return(NA_real_)
  r <- rank(score)
  (sum(r[label == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}

#' Precision@K and recall@K computed month by month, then averaged.
#' This is the supervisor's view: each month, K firms go on the watchlist.
watchlist_metrics <- function(df, score_col, k) {
  by_month <- split(df, df$month)
  res <- lapply(by_month, function(m) {
    top <- head(order(m[[score_col]], decreasing = TRUE), k)
    hits <- sum(m$deteriorate[top])
    data.frame(precision_k = hits / length(top),
               recall_k = if (sum(m$deteriorate) > 0) hits / sum(m$deteriorate) else NA_real_,
               events = sum(m$deteriorate))
  })
  res <- do.call(rbind, res)
  c(precision_k = mean(res$precision_k),
    recall_k = mean(res$recall_k, na.rm = TRUE),
    months = nrow(res))
}
