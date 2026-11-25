# =============================================================================
# 05_rq1_mechanisms.R
# RQ1: Which signals precede a deterioration in timely-response performance?
# Panel logit on the firm-month panel, standard errors clustered by firm
# (outcome windows of consecutive months overlap within a firm).
# Tests H1 (volume surge), H2 (case-mix shift), H3 (early drift),
# H4 (surge x size interaction). See docs/research_design.md, section 4.
#
# Note on H4: in a logit, the sign of an interaction coefficient is not the
# sign of the interaction effect on the probability (Ai and Norton 2003).
# H4 is a claim about probabilities ("small firms are hit harder"), so it is
# judged on the linear probability model (LPM), which is reported next to the
# logit for all terms.
# =============================================================================

source("code/00_config.R")
source("code/utils.R")
load_packages(c("DBI", "duckdb", "data.table", "ggplot2", "scales", "sandwich", "lmtest"))

theme_set(theme_minimal(base_size = 12) +
            theme(plot.title = element_text(face = "bold"),
                  panel.grid.minor = element_blank()))

panel <- as.data.table(load_panel())

# --- Estimation sample ----------------------------------------------------------
key_vars <- c("vol_surge", "casemix_shift", "late_trend", "late_past12", "log_n_base",
              "share_older", "share_servicemember", "share_referral", "share_phone",
              "lag_mean_last3")
d <- panel[has_outcome == TRUE]
d <- d[complete.cases(d[, ..key_vars])]

# standardise continuous predictors: odds ratios are then "per 1 SD" and comparable
z <- function(x) (x - mean(x)) / sd(x)
for (v in key_vars) d[, (paste0(v, "_z")) := z(get(v))]
d[, year_f := factor(year)]
d[, main_product := factor(main_product)]

f_main <- deteriorate ~ vol_surge_z * log_n_base_z + casemix_shift_z + late_trend_z +
  late_past12_z + share_older_z + share_servicemember_z + share_referral_z +
  share_phone_z + lag_mean_last3_z + year_f + main_product

# --- Main model: logit, clustered SE -----------------------------------------
fit <- glm(f_main, data = d, family = binomial())
vc  <- vcovCL(fit, cluster = ~company)
ct  <- coeftest(fit, vcov. = vc)

tidy_or <- function(ct, model_name) {
  est <- ct[, 1]; se <- ct[, 2]
  data.table(term = rownames(ct), estimate = est, std_error = se,
             odds_ratio = exp(est), or_low = exp(est - 1.96 * se), or_high = exp(est + 1.96 * se),
             p_value = ct[, 4], model = model_name)
}
res_main <- tidy_or(ct, "logit_main")
fwrite(res_main, file.path(DIR_TAB, "rq1_logit_main.csv"))

# --- Robustness ----------------------------------------------------------------
rob <- list()

# (a) linear probability model, clustered SE
lpm <- lm(f_main, data = d)
rob$lpm <- tidy_or(coeftest(lpm, vcov. = vcovCL(lpm, cluster = ~company)), "lpm")

# (b) continuous outcome: change in untimely rate
f_cont <- update(f_main, delta_next ~ .)
ols <- lm(f_cont, data = d)
rob$delta <- tidy_or(coeftest(ols, vcov. = vcovCL(ols, cluster = ~company)), "ols_delta_next")

# (c) alternative event thresholds (absolute rise, relative factor)
for (th in list(c(0.03, 1.5), c(0.10, 2))) {
  d[, det_alt := as.integer(late_next3 - late_past12 >= th[1] & late_next3 >= th[2] * late_past12)]
  m <- glm(update(f_main, det_alt ~ .), data = d, family = binomial())
  rob[[paste0("thr_", th[1])]] <- tidy_or(coeftest(m, vcov. = vcovCL(m, cluster = ~company)),
                                          sprintf("logit_abs%.2f_rel%.1f", th[1], th[2]))
}

# (d) stability over time: split sample
for (per in list(c(-Inf, 2019), c(2020, Inf))) {
  dd <- d[year >= per[1] & year <= per[2]]
  dd[, year_f := droplevels(year_f)]; dd[, main_product := droplevels(main_product)]
  m <- glm(f_main, data = dd, family = binomial())
  lab <- if (is.infinite(per[1])) "up_to_2019" else "from_2020"
  rob[[lab]] <- tidy_or(coeftest(m, vcov. = vcovCL(m, cluster = ~company)), paste0("logit_", lab))
}

rob_all <- rbindlist(rob)
fwrite(rob_all, file.path(DIR_TAB, "rq1_robustness.csv"))

# --- Hypothesis verdicts ---------------------------------------------------------
# H1-H3: logit (main model). H4: LPM, i.e. on the probability scale (see header).
hyp <- data.table(
  hypothesis = c("H1 capacity strain", "H2 complexity shift", "H3 early drift", "H4 scale buffer"),
  term       = c("vol_surge_z", "casemix_shift_z", "late_trend_z", "vol_surge_z:log_n_base_z"),
  expected   = c("+", "+", "+", "-"),
  judged_on  = c("logit_main", "logit_main", "logit_main", "lpm")
)
est_all <- rbindlist(list(res_main, rob$lpm))
hyp <- est_all[hyp, on = c("term", model = "judged_on")]
hyp[, observed := ifelse(estimate > 0, "+", "-")]
hyp[, supported := observed == expected & p_value < 0.05]
fwrite(hyp[, .(hypothesis, term, model, expected, observed, estimate, odds_ratio,
               or_low, or_high, p_value, supported)],
       file.path(DIR_TAB, "rq1_hypotheses.csv"))
print(hyp[, .(hypothesis, model, estimate = signif(estimate, 3),
              p_value = signif(p_value, 2), supported)])

# compact comparison of the four hypothesis terms across specifications
cmp <- rbindlist(list(res_main, rob_all))[term %in% hyp$term,
                                          .(model, term, estimate, p_value)]
fwrite(dcast(cmp, term ~ model, value.var = "estimate"), file.path(DIR_TAB, "rq1_robustness_wide.csv"))

# --- Figure: odds ratios of the signal variables ------------------------------
show <- res_main[term %in% c(hyp$term, "late_past12_z", "log_n_base_z",
                             "share_older_z", "share_referral_z", "lag_mean_last3_z")]
labels <- c(vol_surge_z = "Volume surge (H1)", casemix_shift_z = "Case-mix shift (H2)",
            late_trend_z = "Untimely trend (H3)", `vol_surge_z:log_n_base_z` = "Surge x size (H4, logit scale)",
            late_past12_z = "Untimely level, 12m", log_n_base_z = "Firm size (baseline volume)",
            share_older_z = "Share Older American", share_referral_z = "Share referrals",
            lag_mean_last3_z = "Routing lag")
show[, label := factor(labels[term], levels = rev(labels))]
p <- ggplot(show, aes(odds_ratio, label)) +
  geom_vline(xintercept = 1, linetype = "dashed", colour = "grey50") +
  geom_errorbarh(aes(xmin = or_low, xmax = or_high), height = 0.2, colour = "grey40") +
  geom_point(aes(colour = term %in% hyp$term), size = 2.6) +
  scale_colour_manual(values = c(`TRUE` = "#C0392B", `FALSE` = "#2C7FB8"), guide = "none") +
  scale_x_log10() +
  labs(title = "Which signals precede a deterioration?",
       subtitle = "Logit odds ratios per 1 SD, 95% CI clustered by firm; year and sector effects included",
       x = "Odds ratio (log scale)", y = NULL)
ggsave(file.path(DIR_FIG, "fig3_rq1_odds_ratios.png"), p, width = 9, height = 5, dpi = 300, bg = "white")

message(sprintf("RQ1 done: %s firm-months, %d firms, %d events.",
                format(nrow(d), big.mark = ","), uniqueN(d$company), sum(d$deteriorate)))
