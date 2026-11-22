"""Unit and security tests for function/main.py."""

from __future__ import annotations

from contextlib import nullcontext
import io
import json
import logging
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

FUNCTION_DIR = Path(__file__).resolve().parents[1]
if str(FUNCTION_DIR) not in sys.path:
    sys.path.insert(0, str(FUNCTION_DIR))


def _install_dependency_stubs_if_missing() -> None:
    """Provide minimal in-memory stubs when offline without third-party packages."""
    try:
        import flask  # noqa: F401
    except ModuleNotFoundError:
        flask_stub = types.ModuleType("flask")

        class StubResponse:
            def __init__(self, payload: dict) -> None:
                self._payload = payload
                self.data = json.dumps(payload).encode("utf-8")
                self.headers: dict[str, str] = {"Content-Type": "application/json"}

            def get_json(self) -> dict:
                return json.loads(self.data.decode("utf-8"))

        class StubRequest:
            pass

        class StubFlask:
            def __init__(self, _name: str) -> None:
                pass

            def app_context(self):
                return nullcontext()

        flask_stub.Response = StubResponse  # type: ignore[attr-defined]
        flask_stub.Request = StubRequest  # type: ignore[attr-defined]
        flask_stub.Flask = StubFlask  # type: ignore[attr-defined]
        flask_stub.jsonify = lambda payload: StubResponse(payload)  # type: ignore[attr-defined]
        sys.modules["flask"] = flask_stub

    try:
        import functions_framework  # noqa: F401
    except ModuleNotFoundError:
        ff_stub = types.ModuleType("functions_framework")
        ff_stub.http = lambda func: func  # type: ignore[attr-defined]
        sys.modules["functions_framework"] = ff_stub

    try:
        from google import genai  # noqa: F401
    except ModuleNotFoundError:
        google_pkg = sys.modules.get("google")
        if google_pkg is None:
            google_pkg = types.ModuleType("google")
            google_pkg.__path__ = []  # type: ignore[attr-defined]
            sys.modules["google"] = google_pkg

        genai_stub = types.ModuleType("google.genai")

        class StubClient:
            def __init__(self, **kwargs) -> None:
                self.kwargs = kwargs
                self.decisions = MagicMock()

        genai_stub.Client = StubClient  # type: ignore[attr-defined]
        google_pkg.genai = genai_stub  # type: ignore[attr-defined]
        sys.modules["google.genai"] = genai_stub


_install_dependency_stubs_if_missing()

import flask  # noqa: E402
import main  # noqa: E402

_APP = flask.Flask(__name__)


class FakeRequest:
    """Minimal Flask-compatible request double for handler testing."""

    def __init__(
        self,
        *,
        method: str = "POST",
        json_body: object | None = None,
        raw_bytes: bytes | None = None,
        content_length: int | None = None,
    ) -> None:
        self.method = method
        self._json_body = json_body
        if raw_bytes is not None:
            self._raw = raw_bytes
        elif json_body is not None:
            self._raw = json.dumps(json_body).encode("utf-8")
        else:
            self._raw = b""
        self.content_length = (
            len(self._raw) if content_length is None else content_length
        )

    def get_data(self, cache: bool = True, as_text: bool = False):  # noqa: ARG002
        if as_text:
            return self._raw.decode("utf-8", errors="replace")
        return self._raw

    def get_json(self, silent: bool = True):
        if self._json_body is not None:
            return self._json_body
        try:
            return json.loads(self._raw.decode("utf-8"))
        except Exception:  # noqa: BLE001
            if silent:
                return None
            raise


def _make_decision_response(
    choice: str,
    confidence: float,
    noul: float,
    score: float,
) -> types.SimpleNamespace:
    return types.SimpleNamespace(
        answers={
            "category_pred": types.SimpleNamespace(choice=choice, confidence=confidence),
            "is_market_moving": types.SimpleNamespace(noul=noul),
            "editorial_urgency": types.SimpleNamespace(score=score),
        }
    )


class EvaluateBbcNewsTests(unittest.TestCase):
    def setUp(self) -> None:
        main.reset_genai_client()

    def tearDown(self) -> None:
        main.reset_genai_client()

    def _call_handler(self, request: FakeRequest) -> tuple[dict, int, dict]:
        with _APP.app_context():
            response, status = main.evaluate_bbc_news(request)  # type: ignore[arg-type]
        body = response.get_json()
        headers = dict(response.headers)
        return body, status, headers

    def test_valid_batch_preserves_order_and_routing(self) -> None:
        mock_client = MagicMock()
        mock_client.decisions.create.side_effect = [
            _make_decision_response("business", 0.92, 0.85, 2.5),
            _make_decision_response("tech", 0.60, 0.12, 1.0),
        ]

        with (
            patch.dict(os.environ, {"GEMINI_API_KEY": "AIza" + "SyValidTestKey1234567890"}),
            patch.object(main.genai, "Client", return_value=mock_client),
        ):
            req = FakeRequest(
                json_body={
                    "requestId": "bq-job-123",
                    "calls": [
                        ["Bank earnings surge", "Quarterly profits beat forecasts."],
                        ["New gadget preview", "A subtle software update arrived."],
                    ],
                }
            )
            body, status, headers = self._call_handler(req)

        self.assertEqual(status, 200)
        self.assertEqual(headers.get("Cache-Control"), "no-store")
        self.assertEqual(headers.get("X-Content-Type-Options"), "nosniff")
        self.assertEqual(len(body["replies"]), 2)
        self.assertEqual(body["replies"][0]["category_pred"], "business")
        self.assertEqual(body["replies"][0]["route"], "auto_publish")
        self.assertEqual(body["replies"][1]["category_pred"], "tech")
        self.assertEqual(body["replies"][1]["route"], "human_review")

    def test_empty_calls_returns_empty_replies_with_security_headers(self) -> None:
        req = FakeRequest(json_body={"calls": []})
        body, status, headers = self._call_handler(req)

        self.assertEqual(status, 200)
        self.assertEqual(body, {"replies": []})
        self.assertEqual(headers.get("Cache-Control"), "no-store")
        self.assertEqual(headers.get("X-Content-Type-Options"), "nosniff")

    def test_non_post_methods_rejected_with_405(self) -> None:
        for method in ("GET", "PUT", "DELETE"):
            with self.subTest(method=method):
                req = FakeRequest(method=method, json_body={"calls": []})
                body, status, headers = self._call_handler(req)
                self.assertEqual(status, 405)
                self.assertEqual(headers.get("Allow"), "POST")
                self.assertIn("Method not allowed", body["errorMessage"])

    def test_oversized_payload_rejected_with_413(self) -> None:
        with patch.object(main, "MAX_CONTENT_BYTES", 64):
            req_header = FakeRequest(
                raw_bytes=b"{}",
                content_length=128,
            )
            body, status, _ = self._call_handler(req_header)
            self.assertEqual(status, 413)
            self.assertIn("maximum allowed size", body["errorMessage"])

            req_chunked = FakeRequest(
                raw_bytes=b"x" * 100,
                content_length=None,
            )
            req_chunked.content_length = None
            body2, status2, _ = self._call_handler(req_chunked)
            self.assertEqual(status2, 413)
            self.assertIn("maximum allowed size", body2["errorMessage"])

    def test_oversized_batch_rejected_with_400(self) -> None:
        with patch.object(main, "MAX_BATCH_SIZE", 2):
            req = FakeRequest(
                json_body={"calls": [["a", "b"], ["c", "d"], ["e", "f"]]}
            )
            body, status, _ = self._call_handler(req)
            self.assertEqual(status, 400)
            self.assertIn("exceeds maximum allowed", body["errorMessage"])

    def test_malformed_payload_and_rows_handled_gracefully(self) -> None:
        for bad_payload in (
            FakeRequest(raw_bytes=b"not-json"),
            FakeRequest(json_body={"wrong": []}),
            FakeRequest(json_body={"calls": "not-a-list"}),
        ):
            body, status, _ = self._call_handler(bad_payload)
            self.assertEqual(status, 400)
            self.assertIn("errorMessage", body)

        req = FakeRequest(
            json_body={
                "calls": [
                    ["only_title"],
                    ["a", "b", "extra"],
                    [None, "   "],
                ]
            }
        )
        body, status, _ = self._call_handler(req)
        self.assertEqual(status, 200)
        self.assertEqual(len(body["replies"]), 3)
        for reply in body["replies"]:
            self.assertEqual(reply["route"], "human_review")
            self.assertIsNotNone(reply["error"])

    def test_api_key_redacted_from_client_error_and_logs(self) -> None:
        env_secret = "AIza" + "SyMySuperSecretCloudRunKey987654321"
        url_secret = "AIza" + "SyTestSecretKey1234567890abcdefghij"
        mock_client = MagicMock()
        mock_client.decisions.create.side_effect = RuntimeError(
            f"Upstream failed for https://generativelanguage.googleapis.com/v1beta/models:decide"
            f"?key={url_secret} using token {env_secret}"
        )

        log_buffer = io.StringIO()
        handler = logging.StreamHandler(log_buffer)
        handler.setFormatter(logging.Formatter("%(levelname)s:%(message)s"))
        main.logger.addHandler(handler)
        try:
            with (
                patch.dict(os.environ, {"GEMINI_API_KEY": env_secret}),
                patch.object(main.genai, "Client", return_value=mock_client),
            ):
                req = FakeRequest(
                    json_body={
                        "requestId": "req-redaction-test",
                        "calls": [["Headline", "Body text"]],
                    }
                )
                body, status, _ = self._call_handler(req)
        finally:
            main.logger.removeHandler(handler)

        self.assertEqual(status, 200)
        reply = body["replies"][0]
        self.assertEqual(reply["route"], "human_review")
        self.assertNotIn(env_secret, reply["error"])
        self.assertNotIn(url_secret, reply["error"])
        self.assertIn("[REDACTED_API_KEY]", reply["error"])

        logged_text = log_buffer.getvalue()
        self.assertNotIn(env_secret, logged_text)
        self.assertNotIn(url_secret, logged_text)
        self.assertIn("[REDACTED_API_KEY]", logged_text)

    def test_missing_gemini_api_key_fails_closed_even_with_google_api_key(self) -> None:
        clean_env = {
            key: value
            for key, value in os.environ.items()
            if key not in ("GEMINI_API_KEY", "GOOGLE_API_KEY")
        }
        clean_env["GOOGLE_API_KEY"] = "AIza" + "SyAmbientFallbackShouldBeIgnored999"

        with patch.dict(os.environ, clean_env, clear=True):
            with self.assertRaises(RuntimeError) as ctx:
                main.get_genai_client()
            self.assertIn("GEMINI_API_KEY", str(ctx.exception))

    def test_genai_client_receives_explicit_key_and_ms_timeout(self) -> None:
        expected_key = "AIza" + "SyExplicitClientKey1234567890"
        with (
            patch.dict(os.environ, {"GEMINI_API_KEY": expected_key}),
            patch.object(main.genai, "Client") as mock_client_cls,
        ):
            main.get_genai_client()
            mock_client_cls.assert_called_once_with(
                api_key=expected_key,
                http_options={
                    "api_version": "v1beta",
                    "timeout": main.GEMINI_TIMEOUT_MS,
                },
            )

    def test_log_injection_sanitizes_request_id(self) -> None:
        mock_client = MagicMock()
        mock_client.decisions.create.side_effect = ValueError("bad response")

        log_buffer = io.StringIO()
        handler = logging.StreamHandler(log_buffer)
        main.logger.addHandler(handler)
        try:
            with (
                patch.dict(os.environ, {"GEMINI_API_KEY": "AIza" + "SyValidKeyForLogTest1234"}),
                patch.object(main.genai, "Client", return_value=mock_client),
            ):
                req = FakeRequest(
                    json_body={
                        "requestId": "req-1\r\nFAKE_ADMIN_EVENT injected=true",
                        "calls": [["Headline", "Body text"]],
                    }
                )
                _, status, _ = self._call_handler(req)
        finally:
            main.logger.removeHandler(handler)

        self.assertEqual(status, 200)
        first_line = log_buffer.getvalue().splitlines()[0]
        self.assertNotIn("\r", first_line)
        self.assertIn("request_id=req-1FAKE_ADMIN_EVENTinjectedtrue", first_line)

    def test_long_article_is_truncated_to_max_article_chars(self) -> None:
        mock_client = MagicMock()
        mock_client.decisions.create.return_value = _make_decision_response(
            "politics", 0.88, 0.25, 2.0
        )

        long_body = "A" * 500
        with (
            patch.dict(os.environ, {"GEMINI_API_KEY": "AIza" + "SyValidKeyForTruncTest123"}),
            patch.object(main, "MAX_ARTICLE_CHARS", 120),
            patch.object(main.genai, "Client", return_value=mock_client),
        ):
            req = FakeRequest(
                json_body={"calls": [["Title", long_body]]}
            )
            body, status, _ = self._call_handler(req)

        self.assertEqual(status, 200)
        self.assertEqual(body["replies"][0]["category_pred"], "politics")
        sent_input = mock_client.decisions.create.call_args.kwargs["input"]
        self.assertEqual(sent_input, f"Headline: Title\n\nArticle:\n{'A' * 120}")


if __name__ == "__main__":
    unittest.main()
