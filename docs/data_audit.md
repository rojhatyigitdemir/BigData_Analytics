# Data audit: CFPB Consumer Complaint Database

*Checked 25 Nov 2026 against the CFPB data page, field reference and release notes.*

## 1. Short answer: the dates exist

The complaint date is in the source. The **full CSV export** has two date columns:
`Date received` (CFPB receives the complaint) and `Date sent to company`.
If a copy of the data has no dates, it is a **reduced copy**, not the source. Likely causes:

| Copy | Problem |
|---|---|
| CSV opened in **Excel** | Excel shows at most 1,048,576 rows; the full file has millions. Excel may also hide or reformat date columns. Never use Excel as the data source. |
| **Filtered export** from the search page | Since July 2026 (release 23) capped at 100,000 complaints; since June 2026 (release 22) exports follow the columns shown in the web interface. |
| Our early Colab notebook (`DATA.ipynb`) | Kept only 8 columns in SQLite; date parsing assumed `MM/DD/YYYY`. |

**Rule:** the pipeline uses only the full file
<https://files.consumerfinance.gov/ccdb/complaints.csv.zip> (`code/01_download.R`).
`02_ingest_parquet.R` now checks the column names first and stops with a clear
message if `Date received` or other required columns are missing.

## 2. How to get the data

| Route | Use for us |
|---|---|
| Full CSV ZIP (all published complaints, updated daily) | **Main source.** Download once, freeze the download date in the report. |
| Search page, filtered CSV | Not usable: 100,000-row cap. |
| API (`cfpb.github.io/api/ccdb/`) | Optional cross-check of single companies or months; not needed for the pipeline. JSON export was retired in July 2026. |

## 3. Columns in the current full CSV (15)

Release 22 (June 2026) removed `Consumer disputed?` and `Consumer consent provided?`;
release 24 (September 2026) removed the complaint narratives.

| Column | Type | Our use |
|---|---|---|
| Date received | date | **Time axis** of the firm-month panel |
| Product, Sub-product | text | Case mix (product level) |
| Issue, Sub-issue | text | Case mix (product × issue cells), H2 |
| Company public response | text | Not used (chosen after the response: leakage) |
| Company | text | **Panel unit** |
| State | text | Not used in the model (possible extension) |
| ZIP code | text | Not used |
| Tags | text | Shares of Older American / Servicemember complaints |
| Submitted via | text | Channel shares (referral, phone) |
| Date sent to company | date | Data check: delay CFPB → company (`median_days_to_company`) |
| Company response to consumer | text | Not used (leakage: contains "Untimely response") |
| Timely response? | Yes/No | **Outcome** (late = "No") |
| Complaint ID | number | Row identifier, de-duplication check |

## 4. Time issues and how the design handles them

| Issue | Consequence | Decision |
|---|---|---|
| Product/issue categories reorganised on **24 April 2017** | Before/after categories are not comparable; case-mix measures would jump artificially | Panel uses complaints from **May 2017** on (`ANALYSIS_START`). With 12 months of history, the first prediction month is **April 2018**. |
| Publication after company response or after 15 days | The latest complaints may not have a final timely status | Last 2 months dropped (`DROP_LAST_MONTHS`) |
| Database updates daily | Results change with the download date | Record the download date; keep the same file for slides and report |
| Not a statistical sample; complaints referred to other regulators are not published (e.g. banks under $10 bn in assets) | Small banks are missing; volume reflects size and market share | We model **changes within a firm** (rates relative to its own past), not levels across firms; limitation stated in the report |

## 5. Resulting time split (RQ2)

| Period | Months (prediction month *t*) |
|---|---|
| Training | Apr 2018 to Sep 2022 |
| Validation | 2023 |
| Test | 2024 to latest month with a complete 3-month outcome window |

## 6. Checks the pipeline writes (`output/tables/`)

- `raw_columns.csv`: columns found in the raw file, and whether each is required
- `complaints_by_year.csv`: rows, late rate, first/last date, share missing `Date sent to company`, median days to company, per year
- `panel_summary.csv`: firms, months and event rate in the final panel

## Sources

- CFPB, Consumer Complaint Database: <https://www.consumerfinance.gov/data-research/consumer-complaints/>
- Field reference: <https://cfpb.github.io/api/ccdb/fields.html>
- Release notes: <https://cfpb.github.io/api/ccdb/release-notes.html>
