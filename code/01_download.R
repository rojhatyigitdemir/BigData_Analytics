# =============================================================================
# 01_download.R
# Download the full CFPB Consumer Complaint Database (CSV, zipped) into
# data/raw/. The raw file is NOT committed to git (see .gitignore).
# Skips the download if the CSV already exists.
# =============================================================================

source("code/00_config.R")

if (USE_SYNTHETIC) {
  message("USE_SYNTHETIC = TRUE: run code/tools/make_synthetic_data.R instead.")
} else if (file.exists(RAW_CSV)) {
  message("Raw CSV already present: ", RAW_CSV)
} else {
  zip_path <- file.path(DIR_RAW, "complaints.csv.zip")
  options(timeout = 3600)  # the zip is large; allow up to one hour
  message("Downloading ", CFPB_URL, " ...")
  t <- system.time(download.file(CFPB_URL, zip_path, mode = "wb"))[["elapsed"]]
  message(sprintf("Downloaded in %.0f s. Unzipping ...", t))
  unzip(zip_path, exdir = DIR_RAW)
  file.remove(zip_path)
  message("Done: ", RAW_CSV, " (", round(file.size(RAW_CSV) / 1e9, 2), " GB)")
}
