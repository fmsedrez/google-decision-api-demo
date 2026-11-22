-- =============================================================================
-- BigQuery SQL Evaluation & Benchmarking for bigquery-public-data.bbc_news.fulltext
-- Replace YOUR_PROJECT_ID before running in BigQuery Studio (Location: US).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Stratified 50-row sample (10 rows per category) -> Materialize JSON results
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `YOUR_PROJECT_ID.bbc_news_eval.bbc_news_decisions_50` AS
WITH stratified_sample AS (
  SELECT
    title,
    body,
    category AS actual_category,
    ROW_NUMBER() OVER (
      PARTITION BY category
      ORDER BY FARM_FINGERPRINT(CONCAT(COALESCE(title, ''), '|', COALESCE(body, '')))
    ) AS rn
  FROM `bigquery-public-data.bbc_news.fulltext`
  WHERE category IN ('tech', 'sport', 'business', 'politics', 'entertainment')
)
SELECT
  actual_category,
  title,
  body,
  `YOUR_PROJECT_ID.bbc_news_eval.evaluate_article`(title, body) AS decision
FROM stratified_sample
WHERE rn <= 10;


-- -----------------------------------------------------------------------------
-- 2. Overall & Per-Category Classification Accuracy + Confidence Calibration
-- -----------------------------------------------------------------------------
WITH parsed AS (
  SELECT
    actual_category,
    JSON_VALUE(decision, '$.category_pred') AS category_pred,
    SAFE.FLOAT64(decision.category_confidence) AS category_confidence,
    JSON_VALUE(decision, '$.route') AS route,
    JSON_VALUE(decision, '$.error') AS error_msg
  FROM `YOUR_PROJECT_ID.bbc_news_eval.bbc_news_decisions_50`
)
SELECT
  COALESCE(actual_category, 'ALL_CATEGORIES') AS category,
  COUNT(*) AS total_rows,
  COUNTIF(error_msg IS NOT NULL) AS error_rows,
  COUNTIF(category_pred = actual_category) AS correct_rows,
  ROUND(SAFE_DIVIDE(COUNTIF(category_pred = actual_category), COUNT(*)) * 100, 2) AS accuracy_pct,
  ROUND(AVG(category_confidence), 4) AS avg_confidence,
  ROUND(SAFE_DIVIDE(COUNTIF(route = 'human_review'), COUNT(*)) * 100, 2) AS human_review_pct
FROM parsed
GROUP BY ROLLUP(actual_category)
ORDER BY
  CASE WHEN actual_category IS NULL THEN 0 ELSE 1 END,
  category;


-- -----------------------------------------------------------------------------
-- 3. Routing Breakdown: % Routed to "human_review" (category_confidence < 0.75)
--    and Accuracy Comparison (auto_publish vs human_review)
-- -----------------------------------------------------------------------------
WITH parsed AS (
  SELECT
    actual_category,
    JSON_VALUE(decision, '$.category_pred') AS category_pred,
    SAFE.FLOAT64(decision.category_confidence) AS category_confidence,
    JSON_VALUE(decision, '$.route') AS route
  FROM `YOUR_PROJECT_ID.bbc_news_eval.bbc_news_decisions_50`
),
totals AS (
  SELECT COUNT(*) AS n_total FROM parsed
)
SELECT
  route,
  COUNT(*) AS article_count,
  ROUND(SAFE_DIVIDE(COUNT(*), ANY_VALUE(totals.n_total)) * 100, 2) AS share_of_rows_pct,
  ROUND(SAFE_DIVIDE(COUNTIF(category_pred = actual_category), COUNT(*)) * 100, 2) AS accuracy_pct,
  ROUND(AVG(category_confidence), 4) AS avg_confidence,
  ROUND(MIN(category_confidence), 4) AS min_confidence,
  ROUND(MAX(category_confidence), 4) AS max_confidence
FROM parsed
CROSS JOIN totals
GROUP BY route
ORDER BY route;


-- -----------------------------------------------------------------------------
-- 4a. Top 10 Articles Flagged for Market-Moving Probability (noul)
-- -----------------------------------------------------------------------------
SELECT
  actual_category,
  JSON_VALUE(decision, '$.category_pred') AS category_pred,
  ROUND(SAFE.FLOAT64(decision.is_market_moving_prob), 4) AS is_market_moving_prob,
  ROUND(SAFE.FLOAT64(decision.editorial_urgency_score), 4) AS editorial_urgency_score,
  ROUND(SAFE.FLOAT64(decision.category_confidence), 4) AS category_confidence,
  JSON_VALUE(decision, '$.route') AS route,
  title
FROM `YOUR_PROJECT_ID.bbc_news_eval.bbc_news_decisions_50`
WHERE SAFE.FLOAT64(decision.is_market_moving_prob) IS NOT NULL
ORDER BY is_market_moving_prob DESC, editorial_urgency_score DESC
LIMIT 10;


-- -----------------------------------------------------------------------------
-- 4b. Top 10 Articles Flagged for Editorial Urgency Score (0-3 rubric)
-- -----------------------------------------------------------------------------
SELECT
  actual_category,
  JSON_VALUE(decision, '$.category_pred') AS category_pred,
  ROUND(SAFE.FLOAT64(decision.editorial_urgency_score), 4) AS editorial_urgency_score,
  ROUND(SAFE.FLOAT64(decision.is_market_moving_prob), 4) AS is_market_moving_prob,
  ROUND(SAFE.FLOAT64(decision.category_confidence), 4) AS category_confidence,
  JSON_VALUE(decision, '$.route') AS route,
  title
FROM `YOUR_PROJECT_ID.bbc_news_eval.bbc_news_decisions_50`
WHERE SAFE.FLOAT64(decision.editorial_urgency_score) IS NOT NULL
ORDER BY editorial_urgency_score DESC, is_market_moving_prob DESC
LIMIT 10;
