# =============================================================================
# make_pipeline_figure.R
# One picture of the whole pipeline, with the real numbers from the last run.
# For the presentation (slide 4) and the report.
# Run after run_all.R:   Rscript code/tools/make_pipeline_figure.R
# =============================================================================

source("code/00_config.R")
source("code/utils.R")
load_packages(c("data.table", "ggplot2"))

read_if <- function(f) {
  p <- file.path(DIR_TAB, f)
  if (file.exists(p)) fread(p) else NULL
}
fmt <- function(x, digits = 0) {
  if (length(x) == 0 || is.na(x)) return("?")
  formatC(x, format = "f", big.mark = ",", digits = digits)
}

size   <- read_if("storage_size.csv")
byyear <- read_if("complaints_by_year.csv")
panel  <- read_if("panel_summary.csv")

n_complaints <- if (!is.null(byyear)) sum(byyear$n) else NA_real_
csv_gb       <- if (!is.null(size)) size$csv_mb / 1024 else NA_real_
pq_gb        <- if (!is.null(size)) size$parquet_mb / 1024 else NA_real_
yr_from      <- if (!is.null(byyear)) min(byyear$year) else NA
yr_to        <- if (!is.null(byyear)) max(byyear$year) else NA

boxes <- data.table(
  x = 1:4,
  title = c("Raw CSV", "Parquet by year", "Firm-month panel", "Watchlist"),
  body = c(
    sprintf("%s complaints\n%s GB, one row each\n%s-%s",
            fmt(n_complaints), fmt(csv_gb, 1), yr_from, yr_to),
    sprintf("%s GB (%s%% of the CSV)\ncolumnar, compressed\nqueries skip whole years",
            fmt(pq_gb, 1), fmt(100 * pq_gb / csv_gb)),
    sprintf("%s rows, %s firms\none row = firm x month\n%s warning signals",
            fmt(if (!is.null(panel)) panel$rows else NA),
            fmt(if (!is.null(panel)) panel$firms else NA), 10),
    sprintf("%d firms per month\nranked by expected\nextra late responses", PARAMS$WATCHLIST_K)),
  tool = c("downloaded once", "DuckDB, streamed",
           "SQL window functions", "logit / lasso / random forest"))

arrows <- data.table(x = 1:3 + 0.45, xend = 2:4 - 0.45, y = 1, yend = 1)

p <- ggplot() +
  geom_tile(data = boxes, aes(x, 1), width = 0.84, height = 0.62,
            fill = "#EAF0F7", colour = "#1F4E79", linewidth = 0.6) +
  geom_text(data = boxes, aes(x, 1.13, label = title),
            fontface = "bold", size = 4.1, colour = "#1F4E79") +
  geom_text(data = boxes, aes(x, 0.975, label = body), size = 3.1, lineheight = 1.25) +
  geom_segment(data = arrows, aes(x = x, xend = xend, y = y, yend = yend),
               arrow = arrow(length = unit(0.18, "cm"), type = "closed"),
               linewidth = 0.5, colour = "grey35") +
  geom_text(data = boxes, aes(x, 0.845, label = tool),
            size = 2.8, colour = "grey40", fontface = "italic") +
  coord_cartesian(xlim = c(0.5, 4.5), ylim = c(0.70, 1.32)) +
  labs(title = "From 5 GB of complaints to a list a supervisor can act on",
       subtitle = "R never holds the raw data in memory: every reduction happens in SQL, close to the data") +
  theme_void(base_size = 12) +
  theme(plot.title = element_text(face = "bold", hjust = 0, size = 13),
        plot.subtitle = element_text(hjust = 0, size = 9.5, colour = "grey30"),
        plot.margin = margin(12, 12, 12, 12))

ggsave(file.path(DIR_FIG, "fig0_pipeline.png"), p, width = 11, height = 3.1, dpi = 300, bg = "white")
message("Wrote ", file.path(DIR_FIG, "fig0_pipeline.png"))
