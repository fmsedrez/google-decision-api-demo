# Security Policy

## Reporting a Vulnerability

If you discover a security issue in this repository, please do **not** open a public GitHub issue or pull request containing exploit details or secret material. Report the issue privately to the repository maintainer via GitHub Security Advisories or direct contact with reproduction details and impact assessment.

## Guaranteeing Cloud Run-Only Gemini API Key Usage

The primary security goal of this project is ensuring that the Gemini API key can **only** be used by the deployed Cloud Run function (`bbc-news-decisions-rf`) and **only** against the Gemini API (`generativelanguage.googleapis.com`).

`deploy.sh` enforces four independent, fail-closed control layers:

1. **Dedicated Least-Privilege Cloud Run Identity**
   - Creates and binds a dedicated service account (`bbc-news-decisions-sa@<PROJECT_ID>.iam.gserviceaccount.com`) with zero project-level IAM roles.
   - Explicitly rejects the shared default Compute Engine service account (`*-compute@developer.gserviceaccount.com`) so no other Compute Engine, GKE, or Cloud Run workload can inherit Secret Manager access.

2. **Secret Manager Isolation & Version Pinning**
   - Stores the API key in Secret Manager (`gemini-api-key`) and mounts an immutable numeric secret version (`GEMINI_API_KEY=${SECRET_NAME}:${SECRET_VERSION}`) into Cloud Run instead of `:latest` or plaintext env vars.
   - Audits `gcloud secrets get-iam-policy` and fails deployment if any principal other than `RUNTIME_SA` holds `roles/secretmanager.secretAccessor`, or if `allUsers`, `allAuthenticatedUsers`, or `*-compute@developer.gserviceaccount.com` appears anywhere in the secret's IAM policy.

3. **Egress Network Isolation (`Direct VPC Egress` + `Cloud NAT` Static IP)**
   - Creates a dedicated custom VPC network and `/24` egress subnet (`bbc-decisions-egress-subnet`) with **Private Google Access explicitly disabled** (`--no-enable-private-ip-google-access`).
   - Disabling Private Google Access is mandatory: when PGA is enabled on a VPC subnet, calls to `*.googleapis.com` route over Google's internal backbone and bypass Cloud NAT, causing API key IP restrictions to fail with `403 REQUEST_DENIED`.
   - Deploys Cloud Run with `--vpc-egress="all-traffic"` through a Cloud NAT gateway bound exclusively to a reserved regional static external IP (`NAT_IP`).

4. **Control-Plane API Key Lockdown (`apikeys.googleapis.com`)**
   - Restricts the API key with `--api-target=service=generativelanguage.googleapis.com` and `--allowed-ips="${NAT_IP}"`.
   - Runs a mandatory post-update verification gate (`gcloud services api-keys describe`) checking via `jq` that `restrictions.apiTargets` allows only `generativelanguage.googleapis.com` and `restrictions.serverKeyRestrictions.allowedIps` equals `["${NAT_IP}"]`.
   - Fails closed if a caller-supplied `GEMINI_API_KEY` cannot be matched to a managed key in `API_KEY_PROJECT_ID` to enforce these restrictions.

## Application & Endpoint Controls

- **Private Invocation (`--no-allow-unauthenticated`)**: Cloud Run rejects unauthenticated HTTP requests. Only the BigQuery Cloud Resource Connection service account is granted `roles/run.invoker`.
- **Explicit Key Loading**: `function/main.py` requires `GEMINI_API_KEY` explicitly and does not silently fall back to `GOOGLE_API_KEY` or ambient credentials.
- **Secret Redaction**: `redact_secrets` and `_SecretRedactingFilter` scrub API key patterns (`AIza...`), query/header key parameters (`key=`, `api_key=`, `x-goog-api-key=`), bearer tokens, and `GEMINI_API_KEY`/`GOOGLE_API_KEY` environment values from both Cloud Logging tracebacks and BigQuery `decision.error` JSON fields.
- **Input & Resource Limits**: Enforces `POST`-only requests (`405`), request size cap (`MAX_CONTENT_BYTES`, default `2097152` bytes -> `413`), batch size cap (`MAX_BATCH_SIZE`, default `100` -> `400`), article truncation (`MAX_ARTICLE_CHARS`, default `32000`), `requestId` sanitization (CWE-117), upstream timeout (`GEMINI_TIMEOUT_MS=30000`), and `Cache-Control: no-store` / `X-Content-Type-Options: nosniff` headers.

## Security Verification

Run offline repository, dependency, script, and unit security tests:

```bash
./scripts/verify_security.sh
```

Audit a live GCP deployment (verifies Cloud Run SA, VPC egress, subnet `privateIpGoogleAccess == false`, Cloud NAT static IP, API key `allowedIps`/`apiTargets`, Secret Manager IAM, and Cloud Run IAM):

```bash
PROJECT_ID="your-gcp-project-id" ./scripts/verify_security.sh --live
```
