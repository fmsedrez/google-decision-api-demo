"""BigQuery Remote Function backed by Google's Gemini Decisions API (gemini-decision-1)."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import logging
import os
import re
import threading
import traceback
from typing import Any

import flask
import functions_framework
from google import genai

MODEL_ID = "gemini-decision-1"
CONFIDENCE_THRESHOLD = 0.75

_CONTROL_CHAR_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_GOOGLE_API_KEY_RE = re.compile(r"AIza[0-9A-Za-z_-]{20,}")
_KEY_PARAM_RE = re.compile(r"(?i)\b(api[_-]?key|key|x-goog-api-key)\s*([:=])\s*[^\s,&\"']+")
_BEARER_TOKEN_RE = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+")
_SAFE_REQUEST_ID_RE = re.compile(r"[^A-Za-z0-9_.:-]")


def redact_secrets(text: str) -> str:
    """Redact API keys, bearer tokens, and control characters from strings."""
    cleaned = str(text)
    for env_name in ("GEMINI_API_KEY", "GOOGLE_API_KEY"):
        secret = os.environ.get(env_name, "").strip()
        if len(secret) >= 8:
            cleaned = cleaned.replace(secret, "[REDACTED_API_KEY]")
    cleaned = _GOOGLE_API_KEY_RE.sub("[REDACTED_API_KEY]", cleaned)
    cleaned = _KEY_PARAM_RE.sub(r"\1\2[REDACTED_API_KEY]", cleaned)
    cleaned = _BEARER_TOKEN_RE.sub("Bearer [REDACTED_TOKEN]", cleaned)
    return _CONTROL_CHAR_RE.sub("", cleaned)


class _SecretRedactingFilter(logging.Filter):
    """Ensure API keys and control chars never reach log messages or tracebacks."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            rendered = record.getMessage()
        except Exception:  # noqa: BLE001
            rendered = str(record.msg)
        record.msg = redact_secrets(rendered)
        record.args = None

        if record.exc_info:
            exc_type, exc_val, exc_tb = record.exc_info
            formatted_tb = "".join(traceback.format_exception(exc_type, exc_val, exc_tb))
            record.exc_text = redact_secrets(formatted_tb).rstrip("\n")
            record.exc_info = None
        elif record.exc_text:
            record.exc_text = redact_secrets(record.exc_text)

        if record.stack_info:
            record.stack_info = redact_secrets(record.stack_info)
        return True


def _configure_logging() -> logging.Logger:
    level_name = os.getenv("LOG_LEVEL", "INFO").strip().upper()
    logging.basicConfig(level=getattr(logging, level_name, logging.INFO))
    secret_filter = _SecretRedactingFilter()
    root_logger = logging.getLogger()
    for handler in root_logger.handlers:
        handler.addFilter(secret_filter)
    app_logger = logging.getLogger(__name__)
    app_logger.addFilter(secret_filter)
    return app_logger


logger = _configure_logging()


def _env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    """Parse an integer environment variable safely within [minimum, maximum]."""
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        parsed = int(raw.strip())
    except ValueError:
        logger.warning("Invalid integer for %s; using default %d.", name, default)
        return default
    return max(minimum, min(maximum, parsed))


MAX_WORKERS = _env_int("MAX_WORKERS", 8, 1, 32)
MAX_BATCH_SIZE = _env_int("MAX_BATCH_SIZE", 100, 1, 500)
MAX_CONTENT_BYTES = _env_int("MAX_CONTENT_BYTES", 2_097_152, 1024, 10_485_760)
MAX_ARTICLE_CHARS = _env_int("MAX_ARTICLE_CHARS", 32_000, 256, 200_000)
MAX_TITLE_CHARS = 2_000
GEMINI_TIMEOUT_MS = _env_int("GEMINI_TIMEOUT_MS", 30_000, 1_000, 240_000)

# All three Gemini Decisions API question types evaluated in a single forward pass.
DECISION_QUESTIONS: dict[str, dict[str, Any]] = {
    "category_pred": {
        "type": "choice",
        "instructions": (
            "Classify this BBC news article into the single best editorial category."
        ),
        "criteria": {
            "tech": (
                "Technology, computing, consumer electronics, gadgets, internet, "
                "software, cybersecurity, and telecoms."
            ),
            "sport": (
                "Athletics, football, rugby, cricket, tennis, Olympics, tournaments, "
                "teams, and sports figures."
            ),
            "business": (
                "Companies, financial markets, economy, corporate earnings, M&A, "
                "trade, banking, and industry news."
            ),
            "politics": (
                "Government, elections, legislation, public policy, parliaments, "
                "diplomacy, and political parties."
            ),
            "entertainment": (
                "Film, television, music, theatre, arts, awards, celebrities, "
                "and cultural media."
            ),
        },
    },
    "is_market_moving": {
        "type": "noul",
        "instructions": (
            "Does this article contain corporate earnings, M&A, regulatory, or "
            "macroeconomic news likely to move financial markets?"
        ),
        "criteria": {
            "true_description": (
                "Contains material corporate earnings, mergers or acquisitions, "
                "central bank or macroeconomic announcements, major regulatory "
                "rulings, or market-moving financial disclosures."
            ),
            "false_description": (
                "Does not contain material news likely to move equities, bonds, "
                "currencies, or commodity markets."
            ),
        },
    },
    "editorial_urgency": {
        "type": "score",
        "instructions": (
            "Grade the editorial urgency of this news article on the 0 to 3 ordered rubric."
        ),
        "criteria": [
            "Evergreen or feature story with no time sensitivity.",
            "Routine daily coverage or standard incremental update.",
            "Notable developing story with meaningful near-term impact.",
            "Breaking or high-impact event requiring immediate front-page coverage.",
        ],
    },
}

_client: genai.Client | None = None
_client_lock = threading.Lock()


def reset_genai_client() -> None:
    """Clear the cached GenAI client singleton (primarily for tests)."""
    global _client
    with _client_lock:
        _client = None


def get_genai_client() -> genai.Client:
    """Lazily initialize and reuse a v1beta GenAI client across invocations.

    Requires GEMINI_API_KEY explicitly so the function fails closed instead of
    implicitly reading unrelated ambient credentials.
    """
    global _client
    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY environment variable is not configured.")

    if _client is None:
        with _client_lock:
            if _client is None:
                api_key = os.environ.get("GEMINI_API_KEY", "").strip()
                if not api_key:
                    raise RuntimeError(
                        "GEMINI_API_KEY environment variable is not configured."
                    )
                _client = genai.Client(
                    api_key=api_key,
                    http_options={
                        "api_version": "v1beta",
                        "timeout": GEMINI_TIMEOUT_MS,
                    },
                )
    return _client


def _sanitize_request_id(raw_request_id: Any) -> str:
    """Normalize untrusted requestId values to prevent log injection (CWE-117)."""
    if raw_request_id is None:
        return "local"
    cleaned = _SAFE_REQUEST_ID_RE.sub("", str(raw_request_id))[:128]
    return cleaned or "local"


def _sanitize_error_for_client(exc: Exception) -> str:
    """Build a bounded, single-line, secret-free error message for row replies."""
    redacted = redact_secrets(str(exc))
    single_line = re.sub(r"[\r\n\t]+", " ", redacted)
    collapsed = re.sub(r"\s+", " ", single_line).strip()
    if not collapsed:
        return type(exc).__name__
    return f"{type(exc).__name__}: {collapsed[:200]}"


def _json_response(
    body: dict[str, Any],
    status: int,
    extra_headers: dict[str, str] | None = None,
) -> tuple[flask.Response, int]:
    """Build a JSON response with defensive caching and content-type headers."""
    response = flask.jsonify(body)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    if extra_headers:
        for header_name, header_value in extra_headers.items():
            response.headers[header_name] = header_value
    return response, status


def _error_reply(message: str) -> dict[str, Any]:
    """Build a schema-consistent fallback payload for a failed row."""
    return {
        "category_pred": None,
        "category_confidence": None,
        "is_market_moving_prob": None,
        "editorial_urgency_score": None,
        "route": "human_review",
        "error": message,
    }


def evaluate_row(call: Any, row_index: int, request_id: str) -> dict[str, Any]:
    """Evaluate a single [title, body] row via Gemini Decisions API."""
    safe_request_id = _sanitize_request_id(request_id)
    try:
        if not isinstance(call, (list, tuple)) or len(call) != 2:
            return _error_reply(
                f"Expected [title, body] array of length 2, got {type(call).__name__}."
            )

        raw_title, raw_body = call[0], call[1]
        title = ("" if raw_title is None else str(raw_title).strip())[:MAX_TITLE_CHARS]
        body = ("" if raw_body is None else str(raw_body).strip())[:MAX_ARTICLE_CHARS]

        if not title and not body:
            return _error_reply("Both title and body are empty.")

        article_text = f"Headline: {title}\n\nArticle:\n{body}"

        client = get_genai_client()
        response = client.decisions.create(
            model=MODEL_ID,
            input=article_text,
            questions=DECISION_QUESTIONS,
        )

        answers = response.answers
        if not answers:
            return _error_reply("No answers returned by Gemini Decisions API.")

        category_answer = answers["category_pred"]
        market_answer = answers["is_market_moving"]
        urgency_answer = answers["editorial_urgency"]

        category_pred = str(category_answer.choice)
        category_confidence = round(float(category_answer.confidence), 6)
        is_market_moving_prob = round(float(market_answer.noul), 6)
        editorial_urgency_score = round(float(urgency_answer.score), 6)
        route = (
            "auto_publish"
            if category_confidence >= CONFIDENCE_THRESHOLD
            else "human_review"
        )

        return {
            "category_pred": category_pred,
            "category_confidence": category_confidence,
            "is_market_moving_prob": is_market_moving_prob,
            "editorial_urgency_score": editorial_urgency_score,
            "route": route,
        }
    except Exception as exc:  # noqa: BLE001 — isolate row failures from the batch
        safe_error = _sanitize_error_for_client(exc)
        logger.exception(
            "Row evaluation failed (request_id=%s, row_index=%d)",
            safe_request_id,
            row_index,
        )
        return _error_reply(safe_error)


@functions_framework.http
def evaluate_bbc_news(request: flask.Request) -> tuple[flask.Response, int]:
    """BigQuery Remote Function HTTP handler.

    Accepts BigQuery's batch JSON payload:
        {"calls": [[title, body], ...]}

    Returns a matching JSON response with native JSON objects for RETURNS JSON:
        {"replies": [{...}, ...]}
    """
    if getattr(request, "method", "POST") != "POST":
        return _json_response(
            {"errorMessage": "Method not allowed. Use POST."},
            405,
            extra_headers={"Allow": "POST"},
        )

    content_length = getattr(request, "content_length", None)
    if content_length is not None and content_length > MAX_CONTENT_BYTES:
        return _json_response(
            {
                "errorMessage": (
                    f"Request body exceeds maximum allowed size ({MAX_CONTENT_BYTES} bytes)."
                )
            },
            413,
        )

    if hasattr(request, "get_data"):
        raw_data = request.get_data(cache=True, as_text=False)
        if raw_data is not None and len(raw_data) > MAX_CONTENT_BYTES:
            return _json_response(
                {
                    "errorMessage": (
                        f"Request body exceeds maximum allowed size ({MAX_CONTENT_BYTES} bytes)."
                    )
                },
                413,
            )

    payload = request.get_json(silent=True)
    if not isinstance(payload, dict) or not isinstance(payload.get("calls"), list):
        return _json_response(
            {
                "errorMessage": (
                    "Invalid BigQuery remote function payload: missing 'calls' array."
                )
            },
            400,
        )

    calls: list[Any] = payload["calls"]
    if len(calls) > MAX_BATCH_SIZE:
        return _json_response(
            {
                "errorMessage": (
                    f"Batch size {len(calls)} exceeds maximum allowed ({MAX_BATCH_SIZE})."
                )
            },
            400,
        )

    request_id = _sanitize_request_id(payload.get("requestId", "local"))

    if not calls:
        return _json_response({"replies": []}, 200)

    worker_count = max(1, min(MAX_WORKERS, len(calls)))
    if worker_count == 1:
        replies = [evaluate_row(calls[0], 0, request_id)]
    else:
        with ThreadPoolExecutor(max_workers=worker_count) as executor:
            futures = [
                executor.submit(evaluate_row, call, idx, request_id)
                for idx, call in enumerate(calls)
            ]
            # Collecting in submission order guarantees exact alignment with `calls`.
            replies = [future.result() for future in futures]

    return _json_response({"replies": replies}, 200)
