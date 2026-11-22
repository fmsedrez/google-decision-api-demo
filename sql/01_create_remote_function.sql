-- Create or replace the BigQuery Remote Function in the US multi-region.
-- Replace YOUR_PROJECT_ID and YOUR_CLOUD_RUN_URL before running directly in BigQuery Studio.

CREATE OR REPLACE FUNCTION `YOUR_PROJECT_ID.bbc_news_eval.evaluate_article`(
  title STRING,
  body STRING
)
RETURNS JSON
REMOTE WITH CONNECTION `YOUR_PROJECT_ID.US.gemini-decisions-conn`
OPTIONS (
  endpoint = 'https://YOUR_CLOUD_RUN_URL',
  max_batching_rows = 20
);
