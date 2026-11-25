# =============================================================================
# 04_descriptives.R
# Descriptive evidence for the early-warning idea:
#   Fig 1  deterioration events per year (how often does it happen?)
#   Fig 2  event study: average untimely rate and volume surge in the months
#          around the start of a deterioration (does it build up visibly?)
# =============================================================================

source("code/00_config.R")
source("code/utils.R")
load_packages(c("DBI", "duckdb", "data.table", "ggplot2", "scales"))

theme_set(theme_minimal(base_size = 12) +
            theme(plot.title = element_text(face = "bold"),
                  panel.grid.minor = element_blank()))

panel <- as.data.table(load_panel())
d <- panel[has_outcome == TRUE]

# --- Fig 1: events per year ----------------------------------------------------
by_year <- d[, .(firm_months = .N, events = sum(deteriorate),
                 event_rate = mean(deteriorate)), by = year][order(year)]
fwrite(by_year, file.path(DIR_TAB, "events_by_year.csv"))

p1 <- ggplot(by_year, aes(year, event_rate)) +
  geom_col(fill = "#2C7FB8", width = 0.7) +
  geom_text(aes(label = events), vjust = -0.4, size = 3.2) +
  scale_y_continuous(labels = percent_format(accuracy = 0.1),
                     expand = expansion(mult = c(0, 0.15))) +
  labs(title = "Share of monitored firm-months followed by a deterioration",
       subtitle = "Event: untimely rate in next 3 months at least doubles and rises by 5+ pp (labels = number of events)",
       x = NULL, y = "Event rate")
ggsave(file.path(DIR_FIG, "fig1_events_by_year.png"), p1, width = 9, height = 4.5, dpi = 300, bg = "white")

# --- Fig 2: event study around the onset of deterioration ---------------------
# onset = first month of a run of event months for a firm
setorder(panel, company, month)
panel[, onset := deteriorate %in% 1 & !(shift(deteriorate, 1) %in% 1), by = company]
onsets <- panel[onset == TRUE, .(company, onset_month = month)]

rel <- onsets[panel, on = "company", allow.cartesian = TRUE, nomatch = 0]
rel[, k := (as.integer(format(month, "%Y")) - as.integer(format(onset_month, "%Y"))) * 12 +
          (as.integer(format(month, "%m")) - as.integer(format(onset_month, "%m")))]
rel <- rel[k >= -12 & k <= 6]

study <- rel[, .(late_last3 = mean(late_last3, na.rm = TRUE),
                 vol_surge  = mean(vol_surge, na.rm = TRUE),
                 casemix_shift = mean(casemix_shift, na.rm = TRUE),
                 firms = uniqueN(company)), by = k][order(k)]
fwrite(study, file.path(DIR_TAB, "event_study.csv"))

long <- melt(study, id.vars = "k", measure.vars = c("late_last3", "vol_surge"),
             variable.name = "signal")
long[, signal := factor(signal, labels = c("Untimely rate, last 3 months",
                                           "Volume surge (log ratio)"))]
p2 <- ggplot(long, aes(k, value)) +
  geom_vline(xintercept = 0, linetype = "dashed", colour = "grey50") +
  geom_line(colour = "#1B365D", linewidth = 1) + geom_point(colour = "#C0392B", size = 1.6) +
  facet_wrap(~signal, scales = "free_y", ncol = 1) +
  labs(title = "What happens before a firm deteriorates?",
       subtitle = sprintf("Average across %d deterioration onsets; month 0 = month the warning would be issued",
                          nrow(onsets)),
       x = "Months relative to warning month", y = NULL)
ggsave(file.path(DIR_FIG, "fig2_event_study.png"), p2, width = 9, height = 6, dpi = 300, bg = "white")

message("Descriptives done: ", nrow(onsets), " deterioration onsets.")
