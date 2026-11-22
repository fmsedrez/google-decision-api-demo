#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Pre-Release Security & Release Readiness Verification
# ==============================================================================
# Usage:
#   ./scripts/verify_security.sh          # Offline repository & code checks
#   ./scripts/verify_security.sh --live   # Also audit live GCP posture
# ==============================================================================

LIVE_MODE="false"
for arg in "$@"; do
  case "${arg}" in
    --live)
      LIVE_MODE="true"
      ;;
    -h|--help)
      echo "Usage: $0 [--live]"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument '${arg}'. Expected --live or --help." >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FUNCTION_DIR="${ROOT_DIR}/function"

FAILURES=0

pass() {
  printf '[PASS] %s\n' "$1"
}

info() {
  printf '[INFO] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

echo "==> Running pre-release security validation in ${ROOT_DIR}"

# ------------------------------------------------------------------------------
# 1. Secret & Credential Leak Scan (working tree + git history if accessible)
# ------------------------------------------------------------------------------
GAPI_KEY_RE='AIza'"[0-9A-Za-z_-]{35}"
PRIVATE_KEY_RE='BEGIN (RSA |EC |OPENSSH |DSA )?'"PRIVATE KEY"
SA_JSON_RE='"type"[[:space:]]*:[[:space:]]*"'"service_account"'"'

SECRET_MATCHES=""
for pattern in "${GAPI_KEY_RE}" "${PRIVATE_KEY_RE}" "${SA_JSON_RE}"; do
  matches="$(grep -rnE \
    --exclude-dir='.git' \
    --exclude-dir='.venv' \
    --exclude-dir='__pycache__' \
    --exclude-dir='.pytest_cache' \
    "${pattern}" "${ROOT_DIR}" || true)"
  if [[ -n "${matches}" ]]; then
    SECRET_MATCHES="${SECRET_MATCHES}${matches}"$'\n'
  fi
done

if [[ -n "${SECRET_MATCHES}" ]]; then
  fail "Potential hardcoded secret or key material detected:"
  printf '%s\n' "${SECRET_MATCHES}" >&2
else
  pass "No hardcoded API keys, private keys, or service account JSON keys found in workspace."
fi

FORBIDDEN_FILES="$(find "${ROOT_DIR}" \
  -path "${ROOT_DIR}/.git" -prune -o \
  -path "${ROOT_DIR}/.venv" -prune -o \
  \( -name '.env' -o \( -name '.env.*' ! -name '.env.example' \) \
     -o -name '.df-credentials.json' \
     -o -name '*credentials*.json' \
     -o -name '*-key.json' \
     -o -name '*service-account*.json' \
     -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \) \
  -print)"

if [[ -n "${FORBIDDEN_FILES}" ]]; then
  fail "Forbidden credential/secret files found in workspace:"
  printf '%s\n' "${FORBIDDEN_FILES}" >&2
else
  pass "No untracked/unwanted .env, credential JSON, or key files present."
fi

if git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HISTORY_MATCHES=""
  while IFS= read -r rev; do
    [[ -z "${rev}" ]] && continue
    for pattern in "${GAPI_KEY_RE}" "${PRIVATE_KEY_RE}" "${SA_JSON_RE}"; do
      hit="$(git -C "${ROOT_DIR}" grep -nE "${pattern}" "${rev}" || true)"
      if [[ -n "${hit}" ]]; then
        HISTORY_MATCHES="${HISTORY_MATCHES}${hit}"$'\n'
      fi
    done
  done < <(git -C "${ROOT_DIR}" rev-list --all 2>/dev/null || true)

  if [[ -n "${HISTORY_MATCHES}" ]]; then
    fail "Secret pattern matched in git commit history:"
    printf '%s\n' "${HISTORY_MATCHES}" >&2
  else
    pass "Git commit history is clean of secret patterns."
  fi
else
  info "Skipping git history scan (git repository metadata is outside sandbox)."
fi

# Check sql/ and dataform/ for real Cloud Run endpoints or missing placeholders
NON_PLACEHOLDER_URLS="$(grep -rnE 'https://[a-zA-Z0-9._-]+\.run\.app' "${ROOT_DIR}/sql" "${ROOT_DIR}/dataform" || true)"
if [[ -n "${NON_PLACEHOLDER_URLS}" ]]; then
  fail "Concrete .run.app endpoint found in sql/ or dataform/ (expected placeholder YOUR_CLOUD_RUN_URL):"
  printf '%s\n' "${NON_PLACEHOLDER_URLS}" >&2
else
  pass "SQL and Dataform definitions use placeholders (no concrete Cloud Run URLs)."
fi

# ------------------------------------------------------------------------------
# 2. Ignore-File Verification (.gitignore and function/.gcloudignore)
# ------------------------------------------------------------------------------
GITIGNORE="${ROOT_DIR}/.gitignore"
GCLOUDIGNORE="${FUNCTION_DIR}/.gcloudignore"
IGNORE_BEFORE="${FAILURES}"

for required_pattern in '.env' '.env.*' '*credentials*.json' '*-key.json' '*.pem' '*.key' '.df-credentials.json'; do
  if ! grep -Fqx -- "${required_pattern}" "${GITIGNORE}"; then
    fail ".gitignore is missing required secret-exclusion pattern: ${required_pattern}"
  fi
done

for required_gcloud_pattern in '.env' '.env.*' '*credentials*.json' '*-key.json' '*.pem' '*.key' 'tests/'; do
  if ! grep -Fqx -- "${required_gcloud_pattern}" "${GCLOUDIGNORE}"; then
    fail "function/.gcloudignore is missing required exclusion pattern: ${required_gcloud_pattern}"
  fi
done

for required_included in 'pyproject.toml' 'uv.lock'; do
  if grep -Fqx -- "${required_included}" "${GCLOUDIGNORE}"; then
    fail "function/.gcloudignore must NOT exclude ${required_included} (needed by Cloud Run buildpack)."
  fi
done

if [[ "${FAILURES}" -eq "${IGNORE_BEFORE}" ]]; then
  pass ".gitignore and function/.gcloudignore exclusions verified."
fi

# ------------------------------------------------------------------------------
# 3. Dependency & Lockfile Integrity
# ------------------------------------------------------------------------------
if [[ -f "${FUNCTION_DIR}/requirements.txt" ]]; then
  fail "function/requirements.txt exists; remove it so Cloud Run uses uv + uv.lock."
else
  pass "No function/requirements.txt present."
fi

if [[ ! -f "${FUNCTION_DIR}/uv.lock" ]] || ! grep -Fq 'sha256:' "${FUNCTION_DIR}/uv.lock"; then
  fail "function/uv.lock is missing or lacks sha256 package hashes."
else
  pass "function/uv.lock present with sha256 integrity hashes."
fi

if [[ ! -f "${FUNCTION_DIR}/README.md" ]]; then
  fail "function/README.md is missing (referenced by function/pyproject.toml)."
else
  pass "function/README.md exists."
fi

if command -v uv >/dev/null 2>&1; then
  UV_TEMP_CACHE="${UV_CACHE_DIR:-/tmp/uv-cache}"
  if uv lock --check --offline --cache-dir "${UV_TEMP_CACHE}" --project "${FUNCTION_DIR}" >/dev/null; then
    pass "uv lock --check --offline passed."
  else
    fail "uv lock --check --offline failed."
  fi
else
  info "uv CLI not found; skipped uv lock --check."
fi

# ------------------------------------------------------------------------------
# 4. Shell Script Static Validation & Hardened Deployment Controls
# ------------------------------------------------------------------------------
if bash -n "${ROOT_DIR}/deploy.sh" "${ROOT_DIR}/scripts/verify_security.sh"; then
  pass "bash -n syntax checks passed for deploy.sh and scripts/verify_security.sh."
else
  fail "bash -n syntax check failed."
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "${ROOT_DIR}/deploy.sh" "${ROOT_DIR}/scripts/verify_security.sh"; then
    pass "shellcheck passed for deploy.sh and scripts/verify_security.sh."
  else
    fail "shellcheck reported issues."
  fi
else
  info "shellcheck not installed; bash -n passed."
fi

CONTROL_BEFORE="${FAILURES}"
for required_control in \
  'umask 077' \
  '--no-enable-private-ip-google-access' \
  '--vpc-egress="all-traffic"' \
  '--api-target="service=generativelanguage.googleapis.com"' \
  '--allowed-ips="${NAT_IP}"' \
  '--no-allow-unauthenticated' \
  '-compute@developer.gserviceaccount.com'; do
  if ! grep -Fq -- "${required_control}" "${ROOT_DIR}/deploy.sh"; then
    fail "deploy.sh is missing required security control: ${required_control}"
  fi
done
if [[ "${FAILURES}" -eq "${CONTROL_BEFORE}" ]]; then
  pass "deploy.sh enforces all mandatory Cloud Run-exclusive API key controls."
fi

# ------------------------------------------------------------------------------
# 5. Unit & Security Tests
# ------------------------------------------------------------------------------
TEST_PYTHON="${PYTHON_BIN:-python3}"
if "${TEST_PYTHON}" -m unittest discover -s "${FUNCTION_DIR}/tests" -v; then
  pass "Unit and security tests passed (${TEST_PYTHON})."
else
  fail "Unit and security tests failed (${TEST_PYTHON})."
fi

# ------------------------------------------------------------------------------
# 6. Live GCP Posture Audit (--live)
# ------------------------------------------------------------------------------
if [[ "${LIVE_MODE}" == "true" ]]; then
  echo "==> Running live GCP security posture audit..."
  for live_bin in gcloud jq; do
    if ! command -v "${live_bin}" >/dev/null 2>&1; then
      fail "Required CLI '${live_bin}' not found for --live audit."
      exit 1
    fi
  done

  PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
  REGION="${REGION:-us-central1}"
  FUNCTION_NAME="${FUNCTION_NAME:-bbc-news-decisions-rf}"
  SECRET_NAME="${SECRET_NAME:-gemini-api-key}"
  VPC_SUBNET="${VPC_SUBNET:-bbc-decisions-egress-subnet}"
  NAT_IP_NAME="${NAT_IP_NAME:-bbc-decisions-nat-ip}"
  CLOUD_ROUTER="${CLOUD_ROUTER:-bbc-decisions-router}"
  CLOUD_NAT="${CLOUD_NAT:-bbc-decisions-nat}"
  API_KEY_DISPLAY_NAME="${API_KEY_DISPLAY_NAME:-bbc-news-decisions-cloudrun-key}"
  API_KEY_PROJECT_ID="${API_KEY_PROJECT_ID:-${PROJECT_ID}}"
  API_KEY_ID="${API_KEY_ID:-}"

  if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    fail "PROJECT_ID is unset; export PROJECT_ID or run 'gcloud config set project <PROJECT_ID>'."
  else
    # 6a. Cloud Run service audit
    SERVICE_JSON="$(gcloud run services describe "${FUNCTION_NAME}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --format=json)"

    RUNTIME_SA="$(printf '%s' "${SERVICE_JSON}" | jq -r '.spec.template.spec.serviceAccountName // ""')"
    if [[ -z "${RUNTIME_SA}" || "${RUNTIME_SA}" == *-compute@developer.gserviceaccount.com ]]; then
      fail "Cloud Run service '${FUNCTION_NAME}' is not using a dedicated runtime SA (got '${RUNTIME_SA}')."
    else
      pass "Cloud Run runtime SA is dedicated: ${RUNTIME_SA}"
    fi

    VPC_EGRESS_MODE="$(printf '%s' "${SERVICE_JSON}" | jq -r '.spec.template.metadata.annotations["run.googleapis.com/vpc-access-egress"] // ""')"
    if [[ "${VPC_EGRESS_MODE}" != "all-traffic" ]]; then
      fail "Cloud Run Direct VPC Egress must be 'all-traffic' (got '${VPC_EGRESS_MODE}')."
    else
      pass "Cloud Run VPC egress mode verified: all-traffic."
    fi

    SECRET_REF_KEY="$(printf '%s' "${SERVICE_JSON}" | jq -r --arg s "${SECRET_NAME}" '
      [.spec.template.spec.containers[0].env[]?
       | select(.name == "GEMINI_API_KEY")
       | .valueFrom.secretKeyRef]
      | if length == 1 and .[0].name == $s then .[0].key else "" end
    ')"
    if [[ ! "${SECRET_REF_KEY}" =~ ^[0-9]+$ ]]; then
      fail "GEMINI_API_KEY secret mount must pin a numeric version on '${SECRET_NAME}' (got '${SECRET_REF_KEY}')."
    else
      pass "GEMINI_API_KEY secret mount pinned to ${SECRET_NAME}:${SECRET_REF_KEY}."
    fi

    RUN_IAM_JSON="$(gcloud run services get-iam-policy "${FUNCTION_NAME}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --format=json)"
    if printf '%s' "${RUN_IAM_JSON}" | jq -e '[.bindings[]?.members[]?] | any(. == "allUsers" or . == "allAuthenticatedUsers")' >/dev/null; then
      fail "Cloud Run service '${FUNCTION_NAME}' allows unauthenticated public access."
    else
      pass "Cloud Run IAM policy disallows allUsers and allAuthenticatedUsers."
    fi

    # 6b. Subnet Private Google Access & Cloud NAT static IP audit
    PGA_STATE="$(gcloud compute networks subnets describe "${VPC_SUBNET}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}" \
      --format='value(privateIpGoogleAccess)')"
    if [[ "${PGA_STATE}" == "True" || "${PGA_STATE}" == "true" ]]; then
      fail "Subnet '${VPC_SUBNET}' has Private Google Access enabled; Google API calls would bypass Cloud NAT."
    else
      pass "Subnet '${VPC_SUBNET}' has Private Google Access disabled."
    fi

    NAT_IP="$(gcloud compute addresses describe "${NAT_IP_NAME}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}" \
      --format='value(address)')"
    NAT_INFO="$(gcloud compute routers nats describe "${CLOUD_NAT}" \
      --router="${CLOUD_ROUTER}" \
      --region="${REGION}" \
      --project="${PROJECT_ID}" \
      --format=json)"
    if printf '%s' "${NAT_INFO}" | jq -e --arg ip_name "${NAT_IP_NAME}" '
      ([.natIps[]?] | any(endswith("/" + $ip_name)))
    ' >/dev/null; then
      pass "Cloud NAT '${CLOUD_NAT}' uses reserved static IP '${NAT_IP_NAME}' (${NAT_IP})."
    else
      fail "Cloud NAT '${CLOUD_NAT}' is not bound to static IP '${NAT_IP_NAME}'."
    fi

    # 6c. API Key restriction audit
    if [[ -n "${API_KEY_ID}" ]]; then
      KEY_RESOURCE_NAME="projects/${API_KEY_PROJECT_ID}/locations/global/keys/${API_KEY_ID}"
    else
      KEY_RESOURCE_NAME="$(gcloud services api-keys list \
        --project="${API_KEY_PROJECT_ID}" \
        --filter="displayName=\"${API_KEY_DISPLAY_NAME}\"" \
        --format='value(name)' | head -n 1 || true)"
    fi

    if [[ -z "${KEY_RESOURCE_NAME}" ]]; then
      fail "Unable to resolve API key resource '${API_KEY_DISPLAY_NAME}' in project '${API_KEY_PROJECT_ID}'."
    else
      KEY_DESC_JSON="$(gcloud services api-keys describe "${KEY_RESOURCE_NAME}" --format=json)"
      if printf '%s' "${KEY_DESC_JSON}" | jq -e --arg ip "${NAT_IP}" '
        (.restrictions.apiTargets | length == 1 and .[0].service == "generativelanguage.googleapis.com")
        and (.restrictions.serverKeyRestrictions.allowedIps == [$ip])
      ' >/dev/null; then
        pass "API key '${KEY_RESOURCE_NAME}' restricted strictly to generativelanguage.googleapis.com and IP ${NAT_IP}."
      else
        fail "API key '${KEY_RESOURCE_NAME}' restrictions do not match Cloud Run NAT IP (${NAT_IP}) + generativelanguage.googleapis.com."
      fi
    fi

    # 6d. Secret Manager IAM audit
    SECRET_IAM_JSON="$(gcloud secrets get-iam-policy "${SECRET_NAME}" \
      --project="${PROJECT_ID}" \
      --format=json)"
    if printf '%s' "${SECRET_IAM_JSON}" | jq -e --arg sa "serviceAccount:${RUNTIME_SA}" '
      ([.bindings[]? | select(.role == "roles/secretmanager.secretAccessor") | .members[]?] | unique) as $accessors
      | ($accessors | index($sa)) != null
      and ($accessors | all(. == $sa))
      and ([.bindings[]?.members[]?] | any(. == "allUsers" or . == "allAuthenticatedUsers" or endswith("-compute@developer.gserviceaccount.com")) | not)
    ' >/dev/null; then
      pass "Secret '${SECRET_NAME}' IAM accessor role is restricted exclusively to ${RUNTIME_SA}."
    else
      fail "Secret '${SECRET_NAME}' IAM policy grants access beyond ${RUNTIME_SA}."
    fi
  fi
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nSecurity verification FAILED with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nAll security and release readiness checks PASSED.\n'
