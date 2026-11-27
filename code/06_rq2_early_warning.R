# =============================================================================
# 06_rq2_early_warning.R
# RQ2 / H5: Can the signals rank firms that will deteriorate next quarter
# better than the supervisor's simple rules?
#
#   Time split:  train  <= TRAIN_END  (outcome window ends before validation)
#                valid  VALID_START .. TEST_START
#                test   >= TEST_START (never used for fitting or tuning)
#   Models:      logit, lasso-logit (glmnet), random forest (ranger)
#   Baselines:   rank by complaint volume (current practice per OIG 2024)
#                rank by current untimely rate
#   Metrics:     precision@K / recall@K per month (K firms on the watchlist),
#                average precision, ROC-AUC
# Output also includes the latest monthly watchlist (the "application").
# =============================================================================

source("code/00_config.R")
source("code/utils.R")
load_packages(c("DBI", "duckdb", "data.table", "ggplot2", "scales", "glmnet", "ranger"))

theme_set(theme_minimal(base_size = 12) +
            theme(plot.title = element_text(face = "bold"),
                  panel.grid.minor = element_blank()))

panel <- as.data.table(load_panel())

features <- c("vol_surge", "casemix_shift", "late_trend", "late_past12", "late_last3",
              "log_n_past12", "log_n_base", "share_older", "share_servicemember", "share_web",
              "share_phone", "share_referral", "lag_mean_last3", "market_surge")

# missing late_trend (no complaints in prior 9 months) -> 0, i.e. "no trend"
panel[is.na(late_trend), late_trend := 0]
panel[is.na(casemix_shift), casemix_shift := 0]
panel <- panel[complete.cases(panel[, ..features])]
panel[, main_product := factor(main_product)]

train <- panel[has_outcome == TRUE & month <= as.Date(PARAMS$TRAIN_END)]
valid <- panel[has_outcome == TRUE & month >= as.Date(PARAMS$VALID_START) &
                 month < as.Date(PARAMS$TEST_START)]
test  <- panel[has_outcome == TRUE & month >= as.Date(PARAMS$TEST_START)]

split_info <- data.table(set = c("train", "valid", "test"),
                         rows = c(nrow(train), nrow(valid), nrow(test)),
                         events = c(sum(train$deteriorate), sum(valid$deteriorate), sum(test$deteriorate)),
                         first = c(min(train$month), min(valid$month), min(test$month)),
                         last = c(max(train$month), max(valid$month), max(test$month)))
print(split_info)
fwrite(split_info, file.path(DIR_TAB, "rq2_split.csv"))

# --- Models ------------------------------------------------------------------
f_logit <- as.formula(paste("deteriorate ~", paste(c(features, "main_product"), collapse = " + "),
                            "+ vol_surge:log_n_base"))

# design matrix WITHOUT the response, so rows with an unknown outcome (the
# latest months) are kept; na.pass keeps row order aligned with df
x_terms <- delete.response(terms(f_logit))
mm <- function(df) {
  x <- model.matrix(x_terms, model.frame(x_terms, df, na.action = na.pass))[, -1]
  stopifnot(nrow(x) == nrow(df))
  x
}

t_logit <- system.time(
  m_logit <- glm(f_logit, data = train, family = binomial())
)[["elapsed"]]

t_lasso <- system.time(
  m_lasso <- cv.glmnet(mm(train), train$deteriorate, family = "binomial",
                       alpha = 1, nfolds = 10, type.measure = "deviance")
)[["elapsed"]]

t_rf <- system.time(
  m_rf <- ranger(x = as.data.frame(train[, c(features, "main_product"), with = FALSE]),
                 y = factor(train$deteriorate, levels = c(0, 1)),
                 probability = TRUE, num.trees = 500, min.node.size = 20,
                 importance = "permutation", seed = SEED)
)[["elapsed"]]

log_timing("rq2_fit_logit", t_logit)
log_timing("rq2_fit_lasso_cv", t_lasso)
log_timing("rq2_fit_random_forest", t_rf)

score_all <- function(df) {
  df <- copy(df)
  df[, s_volume := n_last3]                                     # baseline (a)
  df[, s_rate   := late_last3]                                  # baseline (b)
  df[, s_logit  := predict(m_logit, newdata = df, type = "response")]
  df[, s_lasso  := as.numeric(predict(m_lasso, newx = mm(df), s = "lambda.min", type = "response"))]
  df[, s_rf     := predict(m_rf, data = as.data.frame(df[, c(features, "main_product"), with = FALSE]))$predictions[, "1"]]
  df
}
# make sure factor levels of new data match training levels
align_levels <- function(df) {
  df[, main_product := factor(as.character(main_product), levels = levels(train$main_product))]
  df[is.na(main_product), main_product := levels(train$main_product)[1]]
  df
}
valid <- score_all(align_levels(valid))
test  <- score_all(align_levels(test))

# --- Evaluation ------------------------------------------------------------------
score_cols <- c(Volume_baseline = "s_volume", Rate_baseline = "s_rate",
                Logit = "s_logit", Lasso = "s_lasso", Random_forest = "s_rf")

evaluate <- function(df, set_name) {
  rbindlist(lapply(names(score_cols), function(nm) {
    sc <- score_cols[[nm]]
    wl <- watchlist_metrics(df, sc, PARAMS$WATCHLIST_K)
    data.table(set = set_name, model = nm,
               avg_precision = average_precision(df[[sc]], df$deteriorate),
               roc_auc = roc_auc(df[[sc]], df$deteriorate),
               precision_at_k = wl[["precision_k"]], recall_at_k = wl[["recall_k"]],
               base_rate = mean(df$deteriorate))
  }))
}
metrics <- rbind(evaluate(valid, "valid"), evaluate(test, "test"))
metrics[, lift_at_k := precision_at_k / base_rate]
fwrite(metrics, file.path(DIR_TAB, "rq2_metrics.csv"))
print(metrics[, lapply(.SD, function(x) if (is.numeric(x)) round(x, 3) else x)])

# --- Figure: precision@K on the test period -------------------------------------
pt <- metrics[set == "test"]
pt[, model := factor(model, levels = names(score_cols))]
pt[, is_baseline := grepl("baseline", model)]
p <- ggplot(pt, aes(model, precision_at_k, fill = is_baseline)) +
  geom_col(width = 0.65) +
  geom_hline(aes(yintercept = base_rate), linetype = "dashed", colour = "grey40") +
  geom_text(aes(label = percent(precision_at_k, accuracy = 1)), vjust = -0.4, size = 3.5) +
  scale_fill_manual(values = c(`TRUE` = "grey65", `FALSE` = "#C0392B"), guide = "none") +
  scale_y_continuous(labels = percent_format(accuracy = 1), expand = expansion(mult = c(0, 0.15))) +
  labs(title = sprintf("Of the %d firms flagged each month, how many really deteriorate?", PARAMS$WATCHLIST_K),
       subtitle = "Test period (never seen in training). Dashed line = share expected from a random pick",
       x = NULL, y = sprintf("Precision@%d", PARAMS$WATCHLIST_K))
ggsave(file.path(DIR_FIG, "fig4_rq2_precision_at_k.png"), p, width = 9, height = 4.8, dpi = 300, bg = "white")

# --- Variable importance (random forest) ---------------------------------------
imp <- data.table(feature = names(m_rf$variable.importance),
                  importance = m_rf$variable.importance)[order(-importance)]
fwrite(imp, file.path(DIR_TAB, "rq2_rf_importance.csv"))

# --- Which ranking should the watchlist use? ----------------------------------
# A supervisor has K slots. Ranking by predicted risk alone tends to fill them
# with very small firms, where a late-response rate doubles on a handful of
# complaints. Ranking by EXPECTED EXTRA LATE RESPONSES instead asks where the
# most consumers are affected: risk x recent volume x the 5pp event threshold.
# A third option keeps plain risk but requires a minimum recent volume.
# We judge the three on two things: how often a flagged firm really
# deteriorates, and how many extra late responses the list actually catches.
best <- metrics[set == "valid" & !grepl("baseline", model)][which.max(avg_precision), model]
K    <- PARAMS$WATCHLIST_K

add_rankings <- function(d) {
  d <- copy(d)
  d[, risk        := get(score_cols[[best]])]
  d[, excess      := risk * n_last3 * PARAMS$EVENT_ABS]
  d[, risk_minvol := fifelse(n_last3 >= PARAMS$WATCHLIST_MIN_N, risk, NA_real_)]
  d
}

rank_labels <- c(risk = "Risk only",
                 excess = "Expected extra late responses",
                 risk_minvol = sprintf("Risk, at least %d complaints", PARAMS$WATCHLIST_MIN_N))

compare_rankings <- function(df) {
  d <- add_rankings(df)
  rbindlist(lapply(names(rank_labels), function(r) {
    per_month <- d[!is.na(get(r)), {
      o <- order(-get(r))[seq_len(min(K, .N))]
      .(precision         = mean(deteriorate[o]),
        extra_late_caught = sum(n_next3[o] * pmax(delta_next[o], 0)),
        extra_late_total  = sum(n_next3 * pmax(delta_next, 0)),
        median_firm_size  = median(n_last3[o]))
    }, by = month]
    data.table(ranking                = rank_labels[[r]],
               precision_at_k         = mean(per_month$precision),
               extra_late_per_month   = mean(per_month$extra_late_caught),
               share_of_extra_late    = sum(per_month$extra_late_caught) /
                                        sum(per_month$extra_late_total),
               median_firm_complaints = median(per_month$median_firm_size))
  }))
}

ranking_cmp <- compare_rankings(test)
fwrite(ranking_cmp, file.path(DIR_TAB, "watchlist_ranking_comparison.csv"))
message("\nWatchlist ranking options, test period (K = ", K, "):")
print(ranking_cmp[, lapply(.SD, function(x) if (is.numeric(x)) round(x, 3) else x)])

# --- The application: latest monthly watchlist --------------------------------
# Rows in the most recent month have no outcome yet; this is what a supervisor
# would receive today. Both rankings are shown so the choice stays visible.
latest <- add_rankings(score_all(align_levels(panel[month == max(month)])))
latest[, `:=`(rank_by_excess = frank(-excess, ties.method = "first"),
              rank_by_risk   = frank(-risk,   ties.method = "first"))]
watchlist <- latest[order(rank_by_excess)][
  , .(rank_by_excess, rank_by_risk, company, month,
      risk                 = round(risk, 3),
      expected_extra_late  = round(excess, 1),
      n_last3,
      late_last3           = round(late_last3, 3),
      late_past12          = round(late_past12, 3),
      vol_surge            = round(vol_surge, 2),
      casemix_shift        = round(casemix_shift, 4))]
fwrite(head(watchlist, 25), file.path(DIR_TAB, "watchlist_latest.csv"))
message("Model used for the watchlist (best on validation): ", best)

saveRDS(list(logit = m_logit, lasso = m_lasso, rf = m_rf, features = features,
             best = best, product_levels = levels(train$main_product)),
        file.path(DIR_AGG, "rq2_models.rds"))
