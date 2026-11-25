# =============================================================================
# make_synthetic_data.R
# Create a small synthetic complaints file with the same columns as the CFPB
# export (data/sample/complaints_synthetic.csv, about 300k rows).
#
# Purpose: anyone (including the lecturer) can run the full pipeline from a
# clean checkout without the 5 GB file:
#     Rscript code/tools/make_synthetic_data.R
#     USE_SYNTHETIC=TRUE Rscript code/run_all.R
#
# The generator plants the mechanisms of hypotheses H1-H4, so the pipeline can
# be checked for recovering them:
#   H1 volume surges raise the untimely probability (with a short delay)
#   H2 shifts toward hard issues raise it
#   H3 some firms drift slowly into failure (early small rise, later large)
#   H4 surges hurt small firms more than large firms
# These numbers are invented and say nothing about real firms.
# =============================================================================

library(data.table)
set.seed(42)

out_file <- "data/sample/complaints_synthetic.csv"
dir.create(dirname(out_file), recursive = TRUE, showWarnings = FALSE)

months   <- seq(as.Date("2014-01-01"), as.Date("2026-10-01"), by = "month")
n_months <- length(months)
n_firms  <- 80

# --- Products and issues (base untimely log-odds per issue) -------------------
issues <- data.table(
  product = rep(c("Credit reporting", "Debt collection", "Mortgage",
                  "Credit card", "Checking or savings account", "Student loan"), each = 3),
  issue = c("Incorrect information on your report", "Problem with a company's investigation", "Improper use of your report",
            "Attempts to collect debt not owed", "Written notification about debt", "Communication tactics",
            "Trouble during payment process", "Struggling to pay mortgage", "Applying for a mortgage",
            "Problem with a purchase shown on your statement", "Fees or interest", "Closing your account",
            "Managing an account", "Opening an account", "Closing an account",
            "Dealing with your lender or servicer", "Struggling to repay your loan", "Getting a loan"),
  hard = rep(c(0, 1, 0), 6)            # the middle issue of each product is "hard"
)
issues[, base_lo := -4.2 + 0.9 * hard + rnorm(.N, 0, 0.2)]

# --- Firms --------------------------------------------------------------------
firms <- data.table(
  firm_id   = seq_len(n_firms),
  company   = sprintf("SYNTH FINANCIAL %02d INC.", seq_len(n_firms)),
  size      = exp(rnorm(n_firms, log(20), 0.9)),           # baseline complaints / month
  quality   = rnorm(n_firms, 0, 0.5),                      # firm-specific log-odds shift
  main_prod = sample(unique(issues$product), n_firms, replace = TRUE),
  state     = sample(c("CA", "TX", "FL", "NY", "GA", "IL", "PA", "OH"), n_firms, replace = TRUE)
)
firms[, size_scale := (log(size) - min(log(size))) / diff(range(log(size)))]  # 0 small .. 1 large

# --- Firm x month latent states -------------------------------------------------
fm <- CJ(firm_id = firms$firm_id, t = seq_len(n_months))
fm <- firms[fm, on = "firm_id"]
setorder(fm, firm_id, t)

episode <- function(n, p_start, len_min, len_max) {
  # binary indicator of random episodes along one firm's timeline
  x <- integer(n); i <- 1
  while (i <= n) {
    if (runif(1) < p_start) {
      len <- sample(len_min:len_max, 1); x[i:min(n, i + len - 1)] <- 1L; i <- i + len
    } else i <- i + 1
  }
  x
}
fm[, surge     := episode(.N, 0.015, 4, 8), by = firm_id]   # H1
fm[, surge_mag := ifelse(surge == 1, runif(.N, 1.8, 3.5), 1)]
fm[, mixshift  := episode(.N, 0.010, 6, 10), by = firm_id]  # H2
fm[, drift_ep  := episode(.N, 0.006, 8, 8), by = firm_id]   # H3
fm[, drift_pos := rowid(rleid(drift_ep)) * drift_ep, by = firm_id]  # months into the episode

# volume: baseline x seasonality x surge
fm[, lambda := size * (1 + 0.15 * sin(2 * pi * t / 12)) * surge_mag * exp(0.004 * t)]
fm[, n := rpois(.N, lambda)]

# strain from a surge acts with a 1-month delay and lasts 2 months after it ends (H1),
# stronger for small firms (H4)
fm[, surge_lag := shift(surge, 1, fill = 0), by = firm_id]
fm[, strain := as.integer(surge_lag == 1 | shift(surge, 2, fill = 0) == 1 | shift(surge, 3, fill = 0) == 1),
   by = firm_id]
fm[, firm_lo := quality +
     strain * (1.8 - 1.2 * size_scale) +                 # H1 + H4
     0.25 * drift_pos * (drift_pos > 0)]                  # H3: slow ramp up
fm[, p_hard := ifelse(mixshift == 1, 0.70, 0.25)]        # H2: mix tilts to hard issues

fm <- fm[n > 0]

# --- Expand to complaint level -------------------------------------------------
cx <- fm[rep(seq_len(.N), n), .(firm_id, company, main_prod, state, t, firm_lo, p_hard)]
cx[, product := ifelse(runif(.N) < 0.7, main_prod,
                       sample(unique(issues$product), .N, replace = TRUE))]
cx[, hard := as.integer(runif(.N) < p_hard)]
# pick an issue in the product: the hard one if hard == 1, else one of the two others
cx[, issue_idx := ifelse(hard == 1, 2L, sample(c(1L, 3L), .N, replace = TRUE))]
iss_lookup <- issues[, .(product, issue, base_lo, k = rowid(product))]
cx <- iss_lookup[cx, on = .(product, k = issue_idx)]

cx[, p_late := plogis(base_lo + firm_lo)]
cx[, late := runif(.N) < p_late]

cx[, date_received := months[t] + sample(0:27, .N, replace = TRUE)]
cx[, date_sent := date_received + sample(0:5, .N, replace = TRUE, prob = c(.5, .25, .1, .07, .05, .03))]
cx[, tags := sample(c("", "Older American", "Servicemember", "Older American, Servicemember"),
                    .N, replace = TRUE, prob = c(.87, .08, .04, .01))]
cx[, submitted_via := sample(c("Web", "Referral", "Phone", "Postal mail", "Fax", "Email"),
                             .N, replace = TRUE, prob = c(.75, .10, .08, .04, .02, .01))]
# 'Company response to consumer' leaks the outcome, as in the real data
cx[, company_response := ifelse(late & runif(.N) < 0.3, "Untimely response",
                         sample(c("Closed with explanation", "Closed with monetary relief",
                                  "Closed with non-monetary relief", "In progress"),
                                .N, replace = TRUE, prob = c(.80, .06, .12, .02)))]

out <- cx[, .(
  `Date received` = format(date_received, "%Y-%m-%d"),
  Product = product,
  `Sub-product` = "",
  Issue = issue,
  `Sub-issue` = "",
  `Consumer complaint narrative` = ifelse(runif(.N) < 0.01,
                                          "Synthetic text, with a comma\nand a line break \"quoted\"", ""),
  `Company public response` = ifelse(runif(.N) < 0.4, "Company has responded to the consumer and the CFPB and chooses not to provide a public response", ""),
  Company = company,
  State = state,
  `ZIP code` = sprintf("%05d", sample(10000:99999, .N, replace = TRUE)),
  Tags = tags,
  `Consumer consent provided?` = "Consent not provided",
  `Submitted via` = submitted_via,
  `Date sent to company` = format(date_sent, "%Y-%m-%d"),
  `Company response to consumer` = company_response,
  `Timely response?` = ifelse(late, "No", "Yes"),
  `Consumer disputed?` = "N/A",
  `Complaint ID` = seq_len(.N) + 1000000L
)]
setorder(out, `Date received`)

fwrite(out, out_file, quote = "auto")
message(sprintf("Wrote %s: %s rows, %.0f MB, untimely rate %.2f%%",
                out_file, format(nrow(out), big.mark = ","),
                file.size(out_file) / 1e6, 100 * mean(out$`Timely response?` == "No")))
