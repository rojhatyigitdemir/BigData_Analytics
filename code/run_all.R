# =============================================================================
# run_all.R
# Run the full pipeline from a clean checkout, in order.
#   Full data:       Rscript code/run_all.R
#   Synthetic data:  USE_SYNTHETIC=TRUE Rscript code/run_all.R
# Run from the repository root.
# =============================================================================

source("code/00_config.R")

# Check packages, disk space and the raw file before the long run.
preflight_ok <- source("code/00_preflight.R", local = new.env())$value
if (!isTRUE(preflight_ok)) stop("Preflight failed; see the messages above.")

if (file.exists(file.path(DIR_TAB, "timings.csv"))) file.remove(file.path(DIR_TAB, "timings.csv"))

if (USE_SYNTHETIC) {
  if (!file.exists(RAW_CSV)) source("code/tools/make_synthetic_data.R")
} else {
  source("code/01_download.R")
}

steps <- c("code/02_ingest_parquet.R",
           "code/03_build_panel.R",
           "code/04_descriptives.R",
           "code/05_rq1_mechanisms.R",
           "code/06_rq2_early_warning.R")

for (s in steps) {
  message("\n==== ", s, " ====")
  secs <- system.time(source(s, local = new.env()))[["elapsed"]]
  message(sprintf("==== %s finished in %.1f s ====", s, secs))
}
