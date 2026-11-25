-- =============================================================================
-- 02_firm_month_panel.sql
-- Build the firm x month panel for the early-warning model.
-- Millions of complaint rows -> one row per firm and month, with rolling
-- 3-, 9- and 12-month windows (past) and a 3-month window (future outcome).
-- See docs/research_design.md, section 5, for all definitions.
--
-- Placeholders: {{ANALYSIS_START}}, {{PANEL_PARQUET}}, {{DROP_LAST_MONTHS}}, {{VALID_START}},
--   {{MIN_CELL_N}}, {{MIN_FIRM_TOTAL}}, {{MIN_PAST12}}, {{MIN_NEXT3}},
--   {{EVENT_ABS}}, {{EVENT_REL}}
-- =============================================================================

-- 0. Analysis window: complaints received after the 2017 taxonomy change only
CREATE OR REPLACE TEMP VIEW complaints_a AS
SELECT * FROM complaints WHERE date_received >= DATE '{{ANALYSIS_START}}';

-- 1. Time bounds: drop the most recent months (complaints may still be open)
CREATE OR REPLACE TEMP TABLE bounds AS
SELECT CAST(date_trunc('month', MAX(date_received)) - to_months({{DROP_LAST_MONTHS}}) AS DATE)
         AS last_month
FROM complaints;

-- 2. Case-mix weights: untimely rate per product-issue cell, estimated on the
--    TRAINING period only (before VALID_START), so test data never leak in.
CREATE OR REPLACE TEMP TABLE w_cell AS
SELECT product, issue, COUNT(*) AS n, AVG(is_late) AS r
FROM complaints_a WHERE date_received < DATE '{{VALID_START}}'
GROUP BY product, issue;

CREATE OR REPLACE TEMP TABLE w_prod AS
SELECT product, AVG(is_late) AS r
FROM complaints_a WHERE date_received < DATE '{{VALID_START}}'
GROUP BY product;

CREATE OR REPLACE TEMP TABLE w_all AS
SELECT AVG(is_late) AS r FROM complaints_a WHERE date_received < DATE '{{VALID_START}}';

-- 3. Aggregate complaints to firm x month (the big reduction step)
CREATE OR REPLACE TEMP TABLE firm_month AS
SELECT
  c.company,
  CAST(date_trunc('month', c.date_received) AS DATE)                    AS month,
  COUNT(*)                                                               AS n,
  SUM(c.is_late)                                                         AS n_late,
  SUM(COALESCE(CASE WHEN wc.n >= {{MIN_CELL_N}} THEN wc.r END, wp.r, wa.r)) AS exp_late,
  SUM(CASE WHEN c.tags ILIKE '%older american%' THEN 1 ELSE 0 END)       AS n_older,
  SUM(CASE WHEN c.tags ILIKE '%servicemember%'  THEN 1 ELSE 0 END)       AS n_svc,
  SUM(CASE WHEN c.submitted_via = 'Web'      THEN 1 ELSE 0 END)          AS n_web,
  SUM(CASE WHEN c.submitted_via = 'Phone'    THEN 1 ELSE 0 END)          AS n_phone,
  SUM(CASE WHEN c.submitted_via = 'Referral' THEN 1 ELSE 0 END)          AS n_referral,
  SUM(CASE WHEN c.date_sent IS NOT NULL
           THEN GREATEST(date_diff('day', c.date_received, c.date_sent), 0) END) AS lag_days,
  SUM(CASE WHEN c.date_sent IS NOT NULL THEN 1 ELSE 0 END)               AS n_lag
FROM complaints_a c
LEFT JOIN w_cell wc ON c.product = wc.product AND c.issue = wc.issue
LEFT JOIN w_prod wp ON c.product = wp.product
CROSS JOIN w_all wa
CROSS JOIN bounds b
WHERE date_trunc('month', c.date_received) <= b.last_month
GROUP BY c.company, CAST(date_trunc('month', c.date_received) AS DATE);

-- 4. Firms large enough to monitor
CREATE OR REPLACE TEMP TABLE firms AS
SELECT company, MIN(month) AS first_month, SUM(n) AS total_n
FROM firm_month
GROUP BY company
HAVING SUM(n) >= {{MIN_FIRM_TOTAL}};

-- 5. Each firm's dominant product in the training period (sector control)
CREATE OR REPLACE TEMP TABLE main_product AS
SELECT company, arg_max(product, cnt) AS main_product
FROM (SELECT company, product, COUNT(*) AS cnt
      FROM complaints_a
      WHERE date_received < DATE '{{VALID_START}}'
      GROUP BY company, product)
GROUP BY company;

-- 6. Market-wide volume per month (all firms) and its surge
CREATE OR REPLACE TEMP TABLE market AS
SELECT month,
       LN((SUM(mn) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) / 3.0 + 1) /
          (SUM(mn) OVER (ORDER BY month ROWS BETWEEN 11 PRECEDING AND 3 PRECEDING) / 9.0 + 1))
         AS market_surge
FROM (SELECT month, SUM(n) AS mn FROM firm_month GROUP BY month);

-- 7. Dense grid: every firm x every month from its first complaint onward,
--    so months with zero complaints count as zero (needed for rolling windows)
CREATE OR REPLACE TEMP TABLE dense AS
SELECT g.company, g.month,
       COALESCE(fm.n, 0)          AS n,
       COALESCE(fm.n_late, 0)     AS n_late,
       COALESCE(fm.exp_late, 0)   AS exp_late,
       COALESCE(fm.n_older, 0)    AS n_older,
       COALESCE(fm.n_svc, 0)      AS n_svc,
       COALESCE(fm.n_web, 0)      AS n_web,
       COALESCE(fm.n_phone, 0)    AS n_phone,
       COALESCE(fm.n_referral, 0) AS n_referral,
       COALESCE(fm.lag_days, 0)   AS lag_days,
       COALESCE(fm.n_lag, 0)      AS n_lag
FROM (
  SELECT f.company, CAST(UNNEST(generate_series(CAST(f.first_month AS TIMESTAMP),
                                                CAST(b.last_month  AS TIMESTAMP),
                                                INTERVAL 1 MONTH)) AS DATE) AS month
  FROM firms f CROSS JOIN bounds b
) g
LEFT JOIN firm_month fm ON fm.company = g.company AND fm.month = g.month;

-- 8. Rolling windows (past: features; future: outcome)
CREATE OR REPLACE TEMP TABLE windows AS
SELECT
  company, month, n,
  COUNT(*)        OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS months_hist,
  SUM(n)          OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS n_past12,
  SUM(n_late)     OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) AS late_n_past12,
  SUM(n)          OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS n_last3,
  SUM(n_late)     OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS late_n_last3,
  SUM(exp_late)   OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS exp_last3,
  SUM(n)          OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 11 PRECEDING AND 3 PRECEDING) AS n_prior9,
  SUM(n_late)     OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 11 PRECEDING AND 3 PRECEDING) AS late_n_prior9,
  SUM(exp_late)   OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 11 PRECEDING AND 3 PRECEDING) AS exp_prior9,
  SUM(n_older)    OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS older_last3,
  SUM(n_svc)      OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS svc_last3,
  SUM(n_web)      OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS web_last3,
  SUM(n_phone)    OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS phone_last3,
  SUM(n_referral) OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS referral_last3,
  SUM(lag_days)   OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS lag_days_last3,
  SUM(n_lag)      OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  AS n_lag_last3,
  COUNT(*)        OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 1 FOLLOWING AND 3 FOLLOWING)  AS months_future,
  SUM(n)          OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 1 FOLLOWING AND 3 FOLLOWING)  AS n_next3,
  SUM(n_late)     OVER (PARTITION BY company ORDER BY month ROWS BETWEEN 1 FOLLOWING AND 3 FOLLOWING)  AS late_n_next3
FROM dense;

-- 9. Features, outcome, eligibility -> Parquet
COPY (
  WITH feat AS (
    SELECT
      w.company, w.month,
      CAST(YEAR(w.month) AS INTEGER)                              AS year,
      COALESCE(mp.main_product, 'Other')                          AS main_product,
      w.n                                                         AS n_month,
      w.n_past12, w.n_last3, w.n_prior9,
      w.late_n_past12 / w.n_past12                                AS late_past12,
      w.late_n_last3  / NULLIF(w.n_last3, 0)                      AS late_last3,
      w.late_n_prior9 / NULLIF(w.n_prior9, 0)                     AS late_prior9,
      LN(w.n_past12)                                              AS log_n_past12,
      -- baseline size: monthly volume BEFORE the last 3 months, so a current
      -- surge does not make a firm look larger than it normally is (H4)
      LN(COALESCE(w.n_prior9, 0) / 9.0 + 1)                       AS log_n_base,
      LN((w.n_last3 / 3.0 + 1) / (COALESCE(w.n_prior9, 0) / 9.0 + 1)) AS vol_surge,
      w.exp_last3 / NULLIF(w.n_last3, 0) - w.exp_prior9 / NULLIF(w.n_prior9, 0) AS casemix_shift,
      w.older_last3    / NULLIF(w.n_last3, 0)                     AS share_older,
      w.svc_last3      / NULLIF(w.n_last3, 0)                     AS share_servicemember,
      w.web_last3      / NULLIF(w.n_last3, 0)                     AS share_web,
      w.phone_last3    / NULLIF(w.n_last3, 0)                     AS share_phone,
      w.referral_last3 / NULLIF(w.n_last3, 0)                     AS share_referral,
      w.lag_days_last3 / NULLIF(w.n_lag_last3, 0)                 AS lag_mean_last3,
      m.market_surge,
      w.n_next3,
      CASE WHEN w.months_future = 3 AND w.n_next3 >= {{MIN_NEXT3}}
           THEN w.late_n_next3 / w.n_next3 END                    AS late_next3
    FROM windows w
    LEFT JOIN main_product mp ON mp.company = w.company
    LEFT JOIN market m        ON m.month = w.month
    WHERE w.months_hist = 12                -- full 12-month history available
      AND w.n_past12 >= {{MIN_PAST12}}      -- enough complaints to measure a rate
  )
  SELECT *,
         late_last3 - late_prior9                       AS late_trend,
         late_next3 IS NOT NULL                         AS has_outcome,
         late_next3 - late_past12                       AS delta_next,
         CASE WHEN late_next3 IS NULL THEN NULL
              WHEN late_next3 - late_past12 >= {{EVENT_ABS}}
               AND late_next3 >= {{EVENT_REL}} * late_past12 THEN 1
              ELSE 0 END                                AS deteriorate
  FROM feat
  ORDER BY company, month
) TO '{{PANEL_PARQUET}}' (FORMAT parquet, COMPRESSION zstd);
