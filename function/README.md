# `bbc-news-decisions-rf` (Cloud Run Function)

HTTP Cloud Run function backing the BigQuery Remote Function `evaluate_article(title, body)`. It evaluates BBC News articles in a single Gemini Decisions API (`gemini-decision-1`) forward pass covering three question types (`choice`, `noul`, and `score`).

## Entry Point & Protocol

- **Entry point**: `evaluate_bbc_news` in `main.py`
- **Method**: `POST` only (`405 Method Not Allowed` with `Allow: POST` otherwise)
- **Request JSON (BigQuery Remote Function wire format)**:
  ```json
  {
    "requestId": "...",
    "calls": [["Headline text", "Article body text"]]
  }
  ```
- **Response JSON**:
  ```json
  {
    "replies": [
      {
        "category_pred": "business",
        "category_confidence": 0.9412,
        "is_market_moving_prob": 0.8821,
        "editorial_urgency_score": 2.15,
        "route": "auto_publish"
      }
    ]
  }
  ```

## Dependency Management (`uv`)

Cloud Run's Python buildpack uses `pyproject.toml`, `.python-version` (`3.15`), and `uv.lock` directly. Do **not** add a `requirements.txt` file in this directory; keeping `pyproject.toml` and `uv.lock` without `requirements.txt` ensures reproducible locked builds via `uv`.

Verify lockfile consistency:
```bash
uv lock --check --project function
```

## Environment Variables

| Variable | Default | Bounds | Description |
| :--- | :--- | :--- | :--- |
| `GEMINI_API_KEY` | *(required)* | non-empty | Injected at runtime from Secret Manager (`SECRET_NAME:VERSION`). Must be explicitly present; ambient fallback keys are ignored. |
| `MAX_WORKERS` | `8` | `1..32` | Thread pool size per batch request. |
| `MAX_BATCH_SIZE` | `100` | `1..500` | Maximum rows accepted in a single `calls` array. |
| `MAX_CONTENT_BYTES` | `2097152` | `1024..10485760` | Maximum HTTP request payload size in bytes (2 MiB default). |
| `MAX_ARTICLE_CHARS` | `32000` | `256..200000` | Maximum body characters sent per article to Gemini. |
| `GEMINI_TIMEOUT_MS` | `30000` | `1000..240000` | Upstream `google-genai` HTTP timeout in milliseconds. |
| `LOG_LEVEL` | `INFO` | standard Python level | Application logging verbosity. |

## Local Testing

Run the unit and security tests from the repository root:
```bash
python3 -m unittest discover -s function/tests -v
```

Or using `uv`:
```bash
uv run --project function python -m unittest discover -s function/tests -v
```

For local HTTP smoke testing with `functions-framework`:
```bash
GEMINI_API_KEY="your-local-test-key" uv run --project function functions-framework --target=evaluate_bbc_news --port=8080
```
