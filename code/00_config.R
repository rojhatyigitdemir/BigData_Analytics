# =============================================================================
# 00_config.R
# Central configuration: paths, analysis parameters, packages.
# Every other script starts with source("code/00_config.R").
# All paths are relative to the repository root (no absolute paths).
# =============================================================================

# --- Data source --------------------------------------------------------------
# Set USE_SYNTHETIC <- TRUE to run the full pipeline on a small synthetic
# dataset (created by code/tools/make_synthetic_data.R). This lets anyone
# reproduce the pipeline without downloading the 5 GB CFPB file.
USE_SYNTHETIC <- as.logical(Sys.getenv("USE_SYNTHETIC", "FALSE"))

CFPB_URL <- "https://files.consumerfinance.gov/ccdb/complaints.csv.zip"

DIR_RAW     <- "data/raw"
DIR_PARQUET <- "data/parquet"
DIR_AGG     <- "data/agg"
DIR_FIG     <- "output/figures"
DIR_TAB     <- "output/tables"
DIR_SQL     <- "code/sql"

RAW_CSV <- if (USE_SYNTHETIC) {
  "data/sample/complaints_synthetic.csv"
} else {
  file.path(DIR_RAW, "complaints.csv")
}

PANEL_PARQUET <- file.path(DIR_AGG, "firm_month_panel.parquet")
DUCKDB_FILE   <- file.path(DIR_AGG, "cfpb.duckdb")

# --- Analysis parameters (see docs/research_design.md, section 5) ------------
PARAMS <- list(
  # firm inclusion and row eligibility
  MIN_FIRM_TOTAL = 500,   # min complaints over the whole sample
  MIN_PAST12     = 30,    # min complaints in past 12 months at month t
  MIN_NEXT3      = 20,    # min complaints in next 3 months (outcome window)
  # deterioration event: late_next3 - late_past12 >= ABS and late_next3 >= REL * late_past12
  EVENT_ABS      = 0.05,
  EVENT_REL      = 2,
  # drop the most recent months (complaints may still be open)
  DROP_LAST_MONTHS = 2,
  # case-mix weights: product-issue cells need this many complaints, else product rate
  MIN_CELL_N     = 500,
  # time split for the early-warning model (RQ2)
  TRAIN_END      = "2022-09-01",  # last month whose 3-month OUTCOME window ends before VALID_START
  VALID_START    = "2023-01-01",
  TEST_START     = "2024-01-01",
  # watchlist size used for precision@K / recall@K
  WATCHLIST_K    = 10
)

if (USE_SYNTHETIC) {
  # the synthetic data are smaller and shorter, so loosen thresholds
  PARAMS$MIN_FIRM_TOTAL <- 200
  PARAMS$MIN_CELL_N     <- 50
  PARAMS$WATCHLIST_K    <- 5
}

SEED <- 20261204
set.seed(SEED)

# --- Packages -----------------------------------------------------------------
# Install once with: install.packages(REQUIRED_PACKAGES)
REQUIRED_PACKAGES <- c("DBI", "duckdb", "data.table", "dplyr", "ggplot2",
                       "scales", "sandwich", "lmtest", "glmnet", "ranger")

load_packages <- function(pkgs = REQUIRED_PACKAGES) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0) {
    stop("Missing packages: ", paste(missing, collapse = ", "),
         "\nInstall with install.packages(c(\"",
         paste(missing, collapse = "\", \""), "\"))", call. = FALSE)
  }
  invisible(lapply(pkgs, library, character.only = TRUE))
}

for (d in c(DIR_RAW, DIR_PARQUET, DIR_AGG, DIR_FIG, DIR_TAB)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}
