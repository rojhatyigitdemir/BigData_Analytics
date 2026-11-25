# Research Design: An Early-Warning System for Complaint-Handling Deterioration

**Project:** UNILU Big Data Analytics, Autumn 2026 (Prof. Dr. Ulrich Matter)
**Team:** Rojhat Yiğit Demir, Massoud Saleh
**Data:** CFPB Consumer Complaint Database, full CSV export (about 5 GB)

---

## 1. Motivation and intended user

The Consumer Financial Protection Bureau (CFPB) forwards consumer complaints to
financial companies and expects a response, generally within 15 calendar days.
Whether each response was timely is published in the public complaint database.

Supervisors already use complaints to decide where to look. The Federal Reserve
OIG reports that the CFPB uses a risk-based approach to select companies for
review and **prioritizes companies with the most complaints** (OIG 2024-MO-C-016).
That rule looks at *levels*: who is big or who is already bad. It does not look
at *change*: who is about to get worse.

**Our user is the supervisor** (CFPB Consumer Response, state regulators, or a
compliance monitoring team). The decision we support is:

> *Every month, which firms should go on a short watchlist because their
> complaint handling is likely to deteriorate in the next quarter?*

This is the logic of supervisory early-warning systems in banking, which try to
flag weak institutions early enough for the supervisor to act (e.g. Gaul, Jones
and Uysal 2019; Suss and Treitel 2019). Bräuning et al. (2019) argue for a
*broader, earlier* definition of distress so that warnings arrive while action
is still possible. We follow that idea: our event is a sharp deterioration in
timeliness, not a final enforcement action.

## 2. Research goal

> **Develop and validate an early-warning system that ranks firms by their risk
> of a sharp deterioration in complaint-response timeliness over the next
> quarter, using only publicly available CFPB complaint data, and identify which
> observable signals drive that risk.**

The goal has an explanatory part (which signals matter, and in which direction)
and a predictive part (does a ranking built on these signals beat the rules a
supervisor would otherwise use).

## 3. Research questions

**RQ1 (Mechanisms).** Which firm-level signals in the complaint flow (volume
shocks, shifts in the complexity of complaints, and recent timeliness trends)
precede a deterioration in a firm's timely-response performance?

**RQ2 (Early warning).** Can a model built on these signals identify the firms
that will deteriorate in the next quarter, out of sample, better than the
supervisory baselines of ranking firms by complaint volume or by their current
untimely rate?

## 4. Hypotheses

| # | Hypothesis | Mechanism | Measure (at month *t*, past data only) | Expected sign |
|---|---|---|---|---|
| H1 | **Capacity strain.** An unexpected surge in a firm's complaint volume raises the probability of deterioration in the next quarter. | A complaint team with fixed staff faces a longer queue; response times rise with load. | `vol_surge` = log ratio of average monthly complaints in the last 3 months vs. the 9 months before | + |
| H2 | **Complexity shift.** A shift in the firm's complaint mix toward issues that are hard to resolve raises the probability of deterioration. | Some issues (e.g. foreclosure, fraud, disputed debts) need more investigation per case. | `casemix_shift` = change in the firm's *expected* untimely rate given its product-issue mix (weights estimated on the training period only) | + |
| H3 | **Early drift.** A small recent rise in the untimely rate predicts a larger rise later, beyond the firm's long-run level. | Deterioration builds up; early misses signal an overloaded or failing process. | `late_trend` = untimely rate in the last 3 months minus the 9 months before | + |
| H4 | **Scale buffer.** Volume surges hurt small firms more than large firms. | Large firms can reallocate staff and have formal complaint operations. | Interaction `vol_surge × log_n_base`, judged on the probability scale (linear probability model) | − |
| H5 | **Predictability.** A model using these signals ranks deteriorating firms better than (a) ranking by complaint volume and (b) ranking by current untimely rate. | If H1 to H4 carry information beyond levels, a supervisor gains from using them. | Precision@10 and average precision on the hold-out period | Model > baselines |

H1 to H4 are tested with the explanatory model (RQ1). H5 is tested with the
predictive comparison (RQ2).

## 5. Unit of analysis and definitions

**Unit:** firm × month. A firm is the CFPB `Company` field.

**Panel construction.** Complaint-level data (millions of rows) are aggregated in
DuckDB to monthly counts per firm, then expanded to a dense firm-month grid so
that months with zero complaints are explicit. Rolling windows are computed with
SQL window functions.

**Firm inclusion.** Firms with at least `MIN_FIRM_TOTAL` complaints over the full
sample (default 500). Smaller firms produce rates too noisy to monitor.

**Row eligibility at month *t*.** At least 30 complaints in the past 12 months
and at least 20 complaints in the next 3 months, so both the baseline and the
outcome rates are measured with reasonable precision.

**Outcome: deterioration event.** Let `late_past12` be the untimely rate over
months *t−11 … t* and `late_next3` the untimely rate over *t+1 … t+3*.

```
deteriorate = 1  if  late_next3 − late_past12 ≥ 0.05
                 and late_next3 ≥ 2 × late_past12
```

That is, the untimely rate at least doubles and rises by at least 5 percentage
points. The thresholds are parameters in `code/00_config.R`. We report results
for alternative thresholds as a robustness check. A continuous version,
`delta_next = late_next3 − late_past12`, is used as a second outcome.

**Predictors** (all computed from months ≤ *t*):

| Variable | Definition |
|---|---|
| `vol_surge` | ln((n_last3/3 + 1) / (n_prior9/9 + 1)) |
| `casemix_shift` | expected untimely rate of last-3-month mix minus that of the prior 9 months |
| `late_trend` | late_last3 − late_prior9 |
| `late_past12` | untimely rate over the past 12 months (level control) |
| `log_n_past12` | log complaints in the past 12 months |
| `log_n_base` | log average monthly complaints in the 9 months *before* the last 3 (baseline size, not inflated by a current surge) |
| `share_older`, `share_servicemember` | share of complaints tagged Older American / Servicemember, last 3 months |
| `share_web`, `share_phone`, `share_referral` | channel shares, last 3 months |
| `lag_mean_last3` | mean days between CFPB receipt and forwarding to the firm |
| `market_surge` | market-wide volume surge (same formula on all firms) |
| `main_product` | the firm's dominant product in the training period (sector control) |

**Excluded on purpose (leakage):** `Company response to consumer` (contains the
value "Untimely response") and `Company public response`. Both are recorded
after the firm acts.

**Data end.** The most recent 2 months are dropped because complaints may still
be open and published without a final response.

## 6. Methods

**RQ1: explanatory panel logit.**

```
logit P(deteriorate_ft = 1) = β1 vol_surge + β2 casemix_shift + β3 late_trend
                              + β4 vol_surge × log_n_base + γ' controls
                              + year effects + sector effects
```

Standard errors are clustered by firm, because outcome windows overlap across
consecutive months of the same firm.

**H4 is judged on the probability scale.** In a logit, the sign of an
interaction coefficient is not the sign of the interaction effect on the
probability (Ai and Norton 2003). H4 says small firms are hit *harder*, which
is a statement about probabilities, so its verdict comes from the linear
probability model. Our synthetic test shows why this matters: the planted
effect (small firms hit harder) appears with the *wrong* sign in the logit
interaction and with the right sign in the LPM. Robustness: linear probability model,
continuous outcome `delta_next`, alternative thresholds, and estimation by
sub-period to check stability over time.

**RQ2: out-of-sample early warning.**

* **Time split, not random split.** Train on months up to 2022 (with the outcome
  window ending before the test period starts), test on 2024 onward. 2023 is a
  validation year for tuning. This mirrors real use: a model trained on the past
  scores the future.
* **Models:** logit, lasso-logit (`glmnet`), random forest (`ranger`).
* **Supervisory baselines:** (a) rank by complaint volume in the last 3 months
  (current practice described by the OIG); (b) rank by current untimely rate.
* **Metrics:** events are rare, so accuracy is not informative. We report
  - precision@K and recall@K per month (K = 10 firms, the size of a realistic
    watchlist), averaged over test months;
  - average precision (area under the precision-recall curve);
  - ROC-AUC for reference.

## 7. Why this is a big data problem, and how we handle it

| Step | Tool | Reason |
|---|---|---|
| Ingest 5 GB CSV | DuckDB `read_csv` → Parquet partitioned by year | Streams the file in parallel; never loads it into R memory |
| Storage | Parquet (columnar, compressed) | Queries read only the columns they need |
| Aggregation and rolling windows | DuckDB SQL on Parquet | Window functions over millions of rows run out of core |
| Comparison | SQLite with indexes (existing script) | Benchmark of a row store vs. a columnar engine |
| Modelling | R (`glm`, `glmnet`, `ranger`) on the firm-month panel | After aggregation the panel is small enough for memory; moving it to Spark would add overhead without benefit |

The central design choice is **aggregate early, model late**: the heavy work is
done once, in SQL, close to the data.

## 8. Threats to validity

* **Prediction, not causation.** H1 to H4 are tested as predictive associations
  with controls, not as causal effects.
* **Regression to the mean.** Firms with a temporarily low rate are more likely
  to "double". We control for the level (`late_past12`) and require a minimum
  absolute rise of 5 percentage points.
* **Firm self-classification.** Firms choose how to classify their responses.
* **Reporting and policy changes.** CFPB processes and complaint volumes change
  over time; we check stability by sub-period and include year effects.
* **Firm names.** The `Company` field is the CFPB's label; mergers and renamings
  are not harmonized.

## 9. Deliverables

1. Reproducible pipeline in `code/` (runs from a clean checkout; a synthetic
   dataset lets anyone run it without the 5 GB file).
2. RQ1 results: odds ratios with clustered confidence intervals.
3. RQ2 results: model vs. baseline comparison table and precision@K plot.
4. A small Shiny "firm watchlist" demo for the presentation.
5. Technical report (`report/report.Rmd`) and slides (`presentation/`).

## 10. References

* Ai, C. and Norton, E. C. (2003). Interaction terms in logit and probit models. *Economics Letters* 80(1), 123–129.
* Bräuning, M., Malikkidou, D., Scalone, S. and Scricco, G. (2019). *A new approach to Early Warning Systems for small European banks.* ECB Working Paper 2348. <https://www.ecb.europa.eu/pub/pdf/scpwps/ecb.wp2348~351ba1be4c.cs.pdf>
* CFPB. *Consumer complaint program* (15-day response expectation). <https://www.consumerfinance.gov/compliance/consumer-complaint-program/>
* CFPB. *How we share complaint data* (field definitions). <https://consumerfinance.gov/complaint/data-use>
* Dou, Y. and Roh, Y. (2021). *Public Disclosure and Consumer Financial Protection.* NYU working paper. <https://www.stern.nyu.edu/sites/default/files/assets/documents/DouRoh2021WP.pdf>
* Gaul, L., Jones, J. and Uysal, P. (2019). *Forecasting High-Risk Composite CAMELS Ratings.* Federal Reserve IFDP 1252. <https://www.federalreserve.gov/econres/ifdp/files/ifdp1252.pdf>
* Office of Inspector General, Federal Reserve Board and CFPB (2024). *The CFPB Effectively Monitors Consumer Complaints but Can Enhance Certain Processes.* Report 2024-MO-C-016. <https://oig.federalreserve.gov/reports/cfpb-consumer-complaints-jun2024.htm>
* Suss, J. and Treitel, H. (2019). *Predicting bank distress in the UK with machine learning.* Bank of England Staff Working Paper 831. <https://www.bankofengland.co.uk/-/media/boe/files/working-paper/2019/predicting-bank-distress-in-the-uk-with-machine-learning.pdf>
