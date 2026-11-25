# =============================================================================
# 00_preflight.R
# Five-second check before the long run. It answers three questions:
#   1. are all R packages installed?
#   2. is there enough free disk space?
#   3. is the raw file the full CFPB export, with the date columns?
# Run it on its own:  Rscript code/00_preflight.R
# run_all.R calls it automatically and stops if something is wrong.
# =============================================================================

source("code/00_config.R")

ok <- TRUE
say <- function(status, msg) {
  message(sprintf("[%s] %s", status, msg))
  if (status == "FAIL") ok <<- FALSE
}

# --- 1. R version and packages ---------------------------------------------------
say("INFO", paste("R version:", getRversion()))

missing_pkgs <- REQUIRED_PACKAGES[
  !vapply(REQUIRED_PACKAGES, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) == 0) {
  say("OK", sprintf("all %d R packages installed", length(REQUIRED_PACKAGES)))
} else {
  say("FAIL", paste0("missing packages: ", paste(missing_pkgs, collapse = ", "),
                     "\n       install them with:\n       install.packages(c(",
                     paste0('"', missing_pkgs, '"', collapse = ", "), "))"))
}

# --- 2. Free disk space ----------------------------------------------------------
# The raw CSV is about 5 GB, the ZIP about 1 GB, Parquet about 1 GB.
needed_gb <- if (USE_SYNTHETIC) 1 else 15

free_gb <- function() {
  out <- tryCatch({
    if (.Platform$OS.type == "windows") {
      drive <- toupper(substr(normalizePath("."), 1, 1))
      txt <- system2("powershell",
                     c("-NoProfile", "-Command",
                       sprintf("(Get-PSDrive -Name %s).Free", drive)),
                     stdout = TRUE, stderr = FALSE)
      as.numeric(txt[1]) / 1024^3
    } else {
      txt <- system2("df", c("-Pk", "."), stdout = TRUE)
      as.numeric(strsplit(trimws(txt[2]), "\\s+")[[1]][4]) * 1024 / 1024^3
    }
  }, error = function(e) NA_real_, warning = function(w) NA_real_)
  if (length(out) == 0 || is.na(out)) NA_real_ else out
}

fg <- free_gb()
if (is.na(fg)) {
  say("WARN", sprintf("could not read free disk space; make sure you have %d GB free", needed_gb))
} else if (fg < needed_gb) {
  say("FAIL", sprintf("only %.1f GB free, about %d GB needed", fg, needed_gb))
} else {
  say("OK", sprintf("%.1f GB free disk space (need about %d GB)", fg, needed_gb))
}

# --- 3. The raw file -------------------------------------------------------------
if (!file.exists(RAW_CSV)) {
  say(if (USE_SYNTHETIC) "INFO" else "WARN",
      sprintf("%s not found yet; %s will create it", RAW_CSV,
              if (USE_SYNTHETIC) "the synthetic generator" else "code/01_download.R"))
} else {
  size_gb <- file.size(RAW_CSV) / 1024^3
  say("INFO", sprintf("raw file: %s (%.2f GB)", RAW_CSV, size_gb))
  if (!USE_SYNTHETIC && size_gb < 1) {
    say("WARN", "the full CFPB export is several GB. A much smaller file is usually an Excel copy or a filtered export; see docs/data_audit.md")
  }
  header <- readLines(RAW_CSV, n = 1, warn = FALSE)
  cols   <- scan(text = header, what = "", sep = ",", quote = "\"", quiet = TRUE)
  cols   <- trimws(gsub("^﻿", "", cols))          # drop a leading byte-order mark
  say("INFO", sprintf("%d columns: %s", length(cols), paste(cols, collapse = " | ")))
  missing_cols <- setdiff(REQUIRED_COLUMNS, cols)
  if (length(missing_cols) == 0) {
    say("OK", "all required columns present, including the date columns")
  } else {
    say("FAIL", paste0("missing columns: ", paste(missing_cols, collapse = ", "),
                       "\n       Use the full CSV from ", CFPB_URL,
                       "\n       Not an Excel copy and not a filtered export. See docs/data_audit.md"))
  }
}

# --- Result ----------------------------------------------------------------------
if (ok) {
  message("\nPreflight passed. You can run the pipeline.")
} else {
  message("\nPreflight failed. Fix the FAIL lines above, then run this again.")
}
if (!interactive() && !ok) quit(status = 1)
invisible(ok)
