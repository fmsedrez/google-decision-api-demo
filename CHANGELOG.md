# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Pruned nested `.venv` directories (such as `function/.venv`) in `scripts/verify_security.sh` so `certifi/cacert.pem` is not flagged as a forbidden secret file.
- Updated placeholder URL check in `scripts/verify_security.sh` to scan `definitions/` and `workflow_settings.yaml` instead of the removed `dataform/` directory.

## [0.1.0] - 2026-11-21

### Added
- Cloud Run HTTP function (`function/main.py`) implementing the BigQuery Remote Function batch wire protocol for `gemini-decision-1` (`choice`, `noul`, and `score` questions in a single forward pass).
- Reproducible Python 3.15 dependency management via `function/pyproject.toml` and `function/uv.lock`, plus `function/README.md`.
- Automated deployment script (`deploy.sh`) provisioning dedicated Cloud Run SA, Secret Manager, API key service restrictions, Cloud Run function, BigQuery dataset, Cloud Resource Connection, and `evaluate_article` Remote Function.
- BigQuery Studio SQL scripts (`sql/01_create_remote_function.sql`, `sql/02_evaluate_bbc_news.sql`) and Dataform project (`dataform/`) for stratified 50-article BBC News evaluation and accuracy/routing marts.
- Unit and security test suite (`function/tests/test_main.py`).
- Pre-release and live GCP security verification script (`scripts/verify_security.sh`), GitHub Actions CI workflow (`.github/workflows/ci.yml`), and `SECURITY.md`.

### Security
- Protected Gemini API key usage through dedicated least-privilege runtime SA (`bbc-news-decisions-sa`), exclusive Secret Manager IAM + numeric version pinning, `apikeys.googleapis.com` restriction to `generativelanguage.googleapis.com` only, and private Cloud Run (`--no-allow-unauthenticated`).
- Hardened `function/main.py` with explicit `GEMINI_API_KEY` validation, API key and bearer token redaction across logs/tracebacks/row errors, `POST`-only enforcement, payload/batch/article bounds, `requestId` sanitization, upstream `HttpOptions.timeout`, and defensive HTTP headers.
- Hardened `.gitignore` and `function/.gcloudignore` against secret, credential, and test leakage.
