# CFPB Response-Risk Radar

**An early-warning system for supervisors: which financial firms are about to
fall behind on answering consumer complaints?**

UNILU Big Data Analytics, Autumn 2026 · Rojhat Yiğit Demir, Massoud Saleh

---

## The idea in one paragraph

The CFPB forwards consumer complaints to financial companies and expects an
answer, generally within 15 days. Supervisors today prioritise firms mainly by
*how many* complaints they receive. We ask a forward-looking question instead:
**which firms are likely to deteriorate in the next quarter?** Using the full
CFPB complaint database (about 5 GB), we build a firm × month panel, test which
signals precede a deterioration (volume surges, harder complaint mix, early
drift in late answers), and train a model that produces a monthly watchlist of
at-risk firms. We compare it with the simple rules a supervisor would otherwise
use.

Full research design (goal, research questions, hypotheses H1–H5, definitions,
methods, threats to validity): **[docs/research_design.md](docs/research_design.md)**

## Research questions

* **RQ1 (Mechanisms):** Which firm-level signals in the complaint flow precede a
  deterioration in timely-response performance?
* **RQ2 (Early warning):** Can these signals identify next-quarter deteriorators
  out of sample better than ranking firms by complaint volume or by their
  current untimely rate?

## Pipeline

```
complaints.csv (5 GB)
   │  02_ingest_parquet.R   DuckDB streams the CSV → Parquet, partitioned by year
   ▼
data/parquet/year=*/        columnar, compressed; leakage columns flagged
   │  03_build_panel.R      DuckDB SQL: aggregation + rolling windows (code/sql/)
   ▼
firm_month_panel.parquet    one row per firm and month (thousands of rows)
   ├─ 04_descriptives.R     events per year, event study
   ├─ 05_rq1_mechanisms.R   panel logit / LPM, firm-clustered SE  (H1–H4)
   └─ 06_rq2_early_warning.R logit, lasso, random forest vs. baselines (H5)
                             + latest monthly watchlist
```

Design principle: **aggregate early, model late.** All heavy work runs once,
in SQL, close to the data. R never holds the raw complaints in memory.

## How to run

Run everything from the repository root.

**1. Install packages (once)**

```r
install.packages(c("DBI", "duckdb", "data.table", "dplyr", "ggplot2", "scales",
                   "sandwich", "lmtest", "glmnet", "ranger"))
```

**1b. Check your setup** (5 seconds)

```r
source("code/00_preflight.R")
```

Reports missing packages, free disk space and whether the raw file has the
required columns. `run_all.R` runs it first and stops if it fails.

If the CFPB file is already somewhere else on your machine, point to it instead
of copying 5 GB into the project:

```r
Sys.setenv(CFPB_CSV = "C:/Users/you/Downloads/complaints.csv")
```

**2a. Full data** (downloads the CFPB export into `data/raw/`, not committed)

```bash
Rscript code/run_all.R
```

If you already have `complaints.csv`, put it in `data/raw/` and the download is skipped.

**2b. Synthetic data** (no download, about 1 minute): a generated file with the
same columns and planted H1–H4 mechanisms, so the pipeline can be checked from a
clean checkout.

```bash
USE_SYNTHETIC=TRUE Rscript code/run_all.R
```

On Windows (PowerShell): `$env:USE_SYNTHETIC="TRUE"; Rscript code/run_all.R`

Outputs go to `output/figures/` and `output/tables/`. Parameters (thresholds,
time split, watchlist size) are set in `code/00_config.R`.

## Repository structure

```
code/
  00_config.R               paths and parameters (relative paths only)
  utils.R                   DuckDB helpers, timing log, ranking metrics
  01_download.R             fetch the CFPB export
  02_ingest_parquet.R       CSV → Parquet (DuckDB)
  03_build_panel.R          firm × month panel (DuckDB)
  04_descriptives.R         figures 1–2
  05_rq1_mechanisms.R       hypotheses H1–H4
  06_rq2_early_warning.R    hypothesis H5 + watchlist
  run_all.R                 runs the steps in order
  sql/                      the SQL behind steps 02 and 03
  tools/make_synthetic_data.R
docs/research_design.md     research goal, RQs, hypotheses, methods
DATA.ipynb                  early exploration in Colab (SQLite ingest)
```

Still to come: `report/report.Rmd` (technical report), `presentation/`,
SQLite vs. DuckDB benchmark, Shiny watchlist demo.

## Data note

Raw data are not in the repository (GitHub limit 100 MB). Source:
<https://www.consumerfinance.gov/data-research/consumer-complaints/>.
Use the **full CSV** only (`code/01_download.R`): Excel copies and filtered web
exports (capped at 100,000 rows) can lack the date columns, and the ingest step
stops if they are missing. See `docs/data_audit.md`.
`Company response to consumer` and `Company public response` are recorded after
the firm acts and are never used as predictors (leakage).

## Use of generative AI

Parts of the code and documentation were drafted with Claude (Anthropic) and
reviewed, tested and edited by the team. The team is responsible for all code
and text.
