#!/usr/bin/env bash
set -euo pipefail
umask 077

# ==============================================================================
# Hardened End-to-End Deployment: Cloud Run Function + BigQuery Remote Function
# ==============================================================================
# Guarantees the Gemini API key is restricted exclusively to this Cloud Run
# service through four defense-in-depth layers:
#   1. Dedicated least-privilege Cloud Run service account (blocks default SA).
#   2. Secret Manager version pinning + IAM access scoped ONLY to runtime SA.
#   3. Dedicated Direct VPC Egress subnet (Private Google Access DISABLED)
#      routing all outbound traffic through Cloud NAT with a static external IP.
#   4. GCP API Key restricted via apikeys.googleapis.com to ONLY
#      generativelanguage.googleapis.com and ONLY the Cloud NAT static IP.
#
# Prerequisites:
#   - gcloud CLI authenticated (`gcloud auth login`)
#   - bq CLI, jq, and uv installed
#   - `function/pyproject.toml` and `function/uv.lock` present (NO requirements.txt)
# ==============================================================================

for required_bin in gcloud bq jq uv; do
  if ! command -v "${required_bin}" >/dev/null 2>&1; then
    echo "ERROR: Required CLI '${required_bin}' is not installed or not in PATH." >&2
    exit 1
  fi
done

validate_regex() {
  local var_name="$1"
  local value="$2"
  local pattern="$3"
  local hint="$4"
  if [[ ! "${value}" =~ ${pattern} ]]; then
    echo "ERROR: Invalid ${var_name} ('${value}'). Expected ${hint}." >&2
    exit 1
  fi
}

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"
BQ_LOCATION="${BQ_LOCATION:-US}"
FUNCTION_NAME="${FUNCTION_NAME:-bbc-news-decisions-rf}"
ENTRY_POINT="${ENTRY_POINT:-evaluate_bbc_news}"
BQ_DATASET="${BQ_DATASET:-bbc_news_eval}"
BQ_CONNECTION_ID="${BQ_CONNECTION_ID:-gemini-decisions-conn}"
SECRET_NAME="${SECRET_NAME:-gemini-api-key}"
MAX_BATCHING_ROWS="${MAX_BATCHING_ROWS:-20}"

RUNTIME_SA_NAME="${RUNTIME_SA_NAME:-bbc-news-decisions-sa}"
VPC_NETWORK="${VPC_NETWORK:-bbc-decisions-egress-vpc}"
VPC_SUBNET="${VPC_SUBNET:-bbc-decisions-egress-subnet}"
VPC_SUBNET_RANGE="${VPC_SUBNET_RANGE:-10.128.0.0/24}"
NAT_IP_NAME="${NAT_IP_NAME:-bbc-decisions-nat-ip}"
CLOUD_ROUTER="${CLOUD_ROUTER:-bbc-decisions-router}"
CLOUD_NAT="${CLOUD_NAT:-bbc-decisions-nat}"

API_KEY_DISPLAY_NAME="${API_KEY_DISPLAY_NAME:-bbc-news-decisions-cloudrun-key}"
API_KEY_PROJECT_ID="${API_KEY_PROJECT_ID:-${PROJECT_ID}}"
API_KEY_ID="${API_KEY_ID:-}"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
  echo "ERROR: Set PROJECT_ID or run 'gcloud config set project <PROJECT_ID>'." >&2
  exit 1
fi

validate_regex "PROJECT_ID" "${PROJECT_ID}" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' "a valid GCP project ID"
validate_regex "REGION" "${REGION}" '^[a-z]+-[a-z0-9]+[0-9]$' "a GCP region (e.g. us-central1)"
validate_regex "BQ_LOCATION" "${BQ_LOCATION}" '^[A-Za-z0-9-]+$' "a BigQuery location (e.g. US)"
validate_regex "FUNCTION_NAME" "${FUNCTION_NAME}" '^[a-z][a-z0-9-]{0,61}[a-z0-9]$' "a valid Cloud Run service name"
validate_regex "ENTRY_POINT" "${ENTRY_POINT}" '^[A-Za-z_][A-Za-z0-9_]*$' "a Python identifier"
validate_regex "BQ_DATASET" "${BQ_DATASET}" '^[A-Za-z0-9_]{1,1024}$' "a BigQuery dataset identifier"
validate_regex "BQ_CONNECTION_ID" "${BQ_CONNECTION_ID}" '^[A-Za-z0-9_-]{1,1024}$' "a BigQuery connection ID"
validate_regex "SECRET_NAME" "${SECRET_NAME}" '^[A-Za-z0-9_-]{1,255}$' "a Secret Manager secret name"
validate_regex "MAX_BATCHING_ROWS" "${MAX_BATCHING_ROWS}" '^[1-9][0-9]{0,2}$' "an integer between 1 and 999"
validate_regex "RUNTIME_SA_NAME" "${RUNTIME_SA_NAME}" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' "a service account ID (6-30 chars)"
validate_regex "VPC_NETWORK" "${VPC_NETWORK}" '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$' "a valid VPC network name"
validate_regex "VPC_SUBNET" "${VPC_SUBNET}" '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$' "a valid VPC subnet name"
validate_regex "VPC_SUBNET_RANGE" "${VPC_SUBNET_RANGE}" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/(1[6-9]|2[0-6])$' "an IPv4 CIDR with /26 or larger prefix"
validate_regex "NAT_IP_NAME" "${NAT_IP_NAME}" '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$' "a valid Compute Engine address name"
validate_regex "CLOUD_ROUTER" "${CLOUD_ROUTER}" '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$' "a valid Cloud Router name"
validate_regex "CLOUD_NAT" "${CLOUD_NAT}" '^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$' "a valid Cloud NAT gateway name"
validate_regex "API_KEY_PROJECT_ID" "${API_KEY_PROJECT_ID}" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' "a valid GCP project ID"
if [[ -n "${API_KEY_ID}" ]]; then
  validate_regex "API_KEY_ID" "${API_KEY_ID}" '^[a-zA-Z0-9-]+$' "an alphanumeric/hyphen API key ID"
fi

RUNTIME_SA="${RUNTIME_SA:-${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"
if [[ "${RUNTIME_SA}" == *-compute@developer.gserviceaccount.com ]]; then
  echo "ERROR: Refusing to use the shared Compute Engine default SA (${RUNTIME_SA}). Use a dedicated Cloud Run SA." >&2
  exit 1
fi
validate_regex "RUNTIME_SA" "${RUNTIME_SA}" '^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$' "a project service account email"

echo "==> Deploying to project=${PROJECT_ID}, region=${REGION}, bq_location=${BQ_LOCATION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTION_DIR="${SCRIPT_DIR}/function"

# 1. Verify uv lockfile is in sync and no requirements.txt exists
uv lock --check --project "${FUNCTION_DIR}"
if [[ -f "${FUNCTION_DIR}/requirements.txt" ]]; then
  echo "ERROR: Remove ${FUNCTION_DIR}/requirements.txt so Cloud Run's Python buildpack uses uv." >&2
  exit 1
fi

# 2. Enable required Google Cloud APIs
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  bigquery.googleapis.com \
  bigqueryconnection.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  compute.googleapis.com \
  apikeys.googleapis.com \
  generativelanguage.googleapis.com \
  --project="${PROJECT_ID}"

if [[ "${API_KEY_PROJECT_ID}" != "${PROJECT_ID}" ]]; then
  gcloud services enable apikeys.googleapis.com --project="${API_KEY_PROJECT_ID}"
fi

# 3. Ensure dedicated least-privilege Cloud Run service account exists (zero project-level roles)
if ! gcloud iam service-accounts describe "${RUNTIME_SA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  SA_ACCOUNT_ID="${RUNTIME_SA%%@*}"
  gcloud iam service-accounts create "${SA_ACCOUNT_ID}" \
    --project="${PROJECT_ID}" \
    --display-name="BBC News Decisions Cloud Run SA" \
    --description="Dedicated least-privilege runtime identity for ${FUNCTION_NAME}"
fi
echo "==> Using dedicated Cloud Run service account: ${RUNTIME_SA}"

# 4. Provision dedicated egress VPC, subnet (PGA DISABLED), static external IP, and Cloud NAT
if ! gcloud compute networks describe "${VPC_NETWORK}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks create "${VPC_NETWORK}" \
    --project="${PROJECT_ID}" \
    --subnet-mode=custom
fi

if ! gcloud compute networks subnets describe "${VPC_SUBNET}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create "${VPC_SUBNET}" \
    --project="${PROJECT_ID}" \
    --network="${VPC_NETWORK}" \
    --region="${REGION}" \
    --range="${VPC_SUBNET_RANGE}" \
    --no-enable-private-ip-google-access
else
  PGA_STATE="$(gcloud compute networks subnets describe "${VPC_SUBNET}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format='value(privateIpGoogleAccess)')"
  if [[ "${PGA_STATE}" == "True" || "${PGA_STATE}" == "true" ]]; then
    echo "==> Disabling Private Google Access on '${VPC_SUBNET}' so Gemini API calls egress via Cloud NAT..."
    gcloud compute networks subnets update "${VPC_SUBNET}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --no-enable-private-ip-google-access
  fi
fi

# Re-verify Private Google Access is disabled (required so Google API traffic uses NAT_IP)
PGA_VERIFY="$(gcloud compute networks subnets describe "${VPC_SUBNET}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format='value(privateIpGoogleAccess)')"
if [[ "${PGA_VERIFY}" == "True" || "${PGA_VERIFY}" == "true" ]]; then
  echo "ERROR: Subnet '${VPC_SUBNET}' still has Private Google Access enabled; Cloud NAT IP restriction would fail." >&2
  exit 1
fi

if ! gcloud compute addresses describe "${NAT_IP_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute addresses create "${NAT_IP_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --network-tier=PREMIUM
fi

NAT_IP="$(gcloud compute addresses describe "${NAT_IP_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format='value(address)')"
validate_regex "NAT_IP" "${NAT_IP}" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "an IPv4 address"
echo "==> Cloud NAT static egress IP: ${NAT_IP}"

if ! gcloud compute routers describe "${CLOUD_ROUTER}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers create "${CLOUD_ROUTER}" \
    --project="${PROJECT_ID}" \
    --network="${VPC_NETWORK}" \
    --region="${REGION}"
fi

if ! gcloud compute routers nats describe "${CLOUD_NAT}" \
  --router="${CLOUD_ROUTER}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute routers nats create "${CLOUD_NAT}" \
    --project="${PROJECT_ID}" \
    --router="${CLOUD_ROUTER}" \
    --region="${REGION}" \
    --nat-custom-subnet-ip-ranges="${VPC_SUBNET}" \
    --nat-external-ip-pool="${NAT_IP_NAME}"
else
  gcloud compute routers nats update "${CLOUD_NAT}" \
    --project="${PROJECT_ID}" \
    --router="${CLOUD_ROUTER}" \
    --region="${REGION}" \
    --nat-custom-subnet-ip-ranges="${VPC_SUBNET}" \
    --nat-external-ip-pool="${NAT_IP_NAME}"
fi

# 5. Provision or restrict the Gemini API key exclusively to Cloud Run NAT_IP + Gemini API
set +x
KEY_RESOURCE_NAME=""
EFFECTIVE_API_KEY=""

if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  # Managed Key Mode: auto-provision or reconcile a GCP API key locked to NAT_IP
  if [[ -n "${API_KEY_ID}" ]]; then
    KEY_RESOURCE_NAME="projects/${API_KEY_PROJECT_ID}/locations/global/keys/${API_KEY_ID}"
  else
    KEY_RESOURCE_NAME="$(gcloud services api-keys list \
      --project="${API_KEY_PROJECT_ID}" \
      --filter="displayName=\"${API_KEY_DISPLAY_NAME}\"" \
      --format='value(name)' | head -n 1 || true)"
  fi

  if [[ -z "${KEY_RESOURCE_NAME}" ]]; then
    echo "==> Creating restricted Gemini API key '${API_KEY_DISPLAY_NAME}' in project '${API_KEY_PROJECT_ID}'..."
    gcloud services api-keys create \
      --project="${API_KEY_PROJECT_ID}" \
      --display-name="${API_KEY_DISPLAY_NAME}" \
      --api-target="service=generativelanguage.googleapis.com" \
      --allowed-ips="${NAT_IP}" \
      --quiet >/dev/null

    KEY_RESOURCE_NAME="$(gcloud services api-keys list \
      --project="${API_KEY_PROJECT_ID}" \
      --filter="displayName=\"${API_KEY_DISPLAY_NAME}\"" \
      --format='value(name)' | head -n 1 || true)"
    if [[ -z "${KEY_RESOURCE_NAME}" ]]; then
      echo "ERROR: Failed to resolve newly created API key resource '${API_KEY_DISPLAY_NAME}'." >&2
      exit 1
    fi
  else
    echo "==> Updating API key restrictions on '${KEY_RESOURCE_NAME}'..."
    gcloud services api-keys update "${KEY_RESOURCE_NAME}" \
      --api-target="service=generativelanguage.googleapis.com" \
      --allowed-ips="${NAT_IP}" \
      --quiet >/dev/null
  fi

  EFFECTIVE_API_KEY="$(gcloud services api-keys get-key-string "${KEY_RESOURCE_NAME}" --format='value(keyString)')"
else
  # Caller-Provided Key Mode (Fail-Closed): key MUST be managed in API_KEY_PROJECT_ID
  # so we can enforce and verify serverKeyRestrictions.allowedIps == [NAT_IP].
  if [[ -n "${API_KEY_ID}" ]]; then
    CANDIDATE_NAME="projects/${API_KEY_PROJECT_ID}/locations/global/keys/${API_KEY_ID}"
    CANDIDATE_STR="$(gcloud services api-keys get-key-string "${CANDIDATE_NAME}" --format='value(keyString)' 2>/dev/null || true)"
    if [[ "${CANDIDATE_STR}" == "${GEMINI_API_KEY}" ]]; then
      KEY_RESOURCE_NAME="${CANDIDATE_NAME}"
    fi
    unset CANDIDATE_STR
  else
    while IFS= read -r candidate_name; do
      [[ -z "${candidate_name}" ]] && continue
      candidate_str="$(gcloud services api-keys get-key-string "${candidate_name}" --format='value(keyString)' 2>/dev/null || true)"
      if [[ "${candidate_str}" == "${GEMINI_API_KEY}" ]]; then
        KEY_RESOURCE_NAME="${candidate_name}"
        unset candidate_str
        break
      fi
      unset candidate_str
    done < <(gcloud services api-keys list --project="${API_KEY_PROJECT_ID}" --format='value(name)')
  fi

  if [[ -z "${KEY_RESOURCE_NAME}" ]]; then
    echo "ERROR: Provided GEMINI_API_KEY was not found in project '${API_KEY_PROJECT_ID}'." >&2
    echo "       Fail-closed policy refuses to deploy an unrestricted or unmanaged API key." >&2
    echo "       Unset GEMINI_API_KEY to let deploy.sh create a Cloud Run-locked key automatically," >&2
    echo "       or set API_KEY_PROJECT_ID (and optionally API_KEY_ID) to the key's owning GCP project." >&2
    exit 1
  fi

  echo "==> Enforcing IP and API restrictions on provided API key '${KEY_RESOURCE_NAME}'..."
  gcloud services api-keys update "${KEY_RESOURCE_NAME}" \
    --api-target="service=generativelanguage.googleapis.com" \
    --allowed-ips="${NAT_IP}" \
    --quiet >/dev/null
  EFFECTIVE_API_KEY="${GEMINI_API_KEY}"
fi

if [[ -z "${EFFECTIVE_API_KEY}" ]]; then
  echo "ERROR: Resolved Gemini API key string is empty." >&2
  exit 1
fi

# Mandatory verification gate on API key restrictions
KEY_DESC_JSON="$(gcloud services api-keys describe "${KEY_RESOURCE_NAME}" --format=json)"
if ! printf '%s' "${KEY_DESC_JSON}" | jq -e --arg ip "${NAT_IP}" '
  (.restrictions.apiTargets | length == 1 and .[0].service == "generativelanguage.googleapis.com")
  and (.restrictions.serverKeyRestrictions.allowedIps == [$ip])
' >/dev/null; then
  echo "ERROR: API key '${KEY_RESOURCE_NAME}' failed restriction verification (expected ONLY generativelanguage.googleapis.com and allowedIps=[${NAT_IP}])." >&2
  exit 1
fi
echo "==> Verified API key '${KEY_RESOURCE_NAME}' is locked to generativelanguage.googleapis.com and IP ${NAT_IP}"

# 6. Store Gemini API key in Secret Manager, pin exact version, and lock IAM to RUNTIME_SA
if ! gcloud secrets describe "${SECRET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  printf '%s' "${EFFECTIVE_API_KEY}" | gcloud secrets create "${SECRET_NAME}" \
    --replication-policy="automatic" \
    --data-file=- \
    --project="${PROJECT_ID}" \
    --quiet
else
  CURRENT_SECRET_VAL="$(gcloud secrets versions access latest --secret="${SECRET_NAME}" --project="${PROJECT_ID}" 2>/dev/null || true)"
  if [[ "${CURRENT_SECRET_VAL}" != "${EFFECTIVE_API_KEY}" ]]; then
    printf '%s' "${EFFECTIVE_API_KEY}" | gcloud secrets versions add "${SECRET_NAME}" \
      --data-file=- \
      --project="${PROJECT_ID}" \
      --quiet
  fi
  unset CURRENT_SECRET_VAL
fi
unset EFFECTIVE_API_KEY

LATEST_VERSION_NAME="$(gcloud secrets versions list "${SECRET_NAME}" \
  --project="${PROJECT_ID}" \
  --filter="state=ENABLED" \
  --sort-by="~createTime" \
  --limit=1 \
  --format='value(name)')"
SECRET_VERSION="${LATEST_VERSION_NAME##*/}"
validate_regex "SECRET_VERSION" "${SECRET_VERSION}" '^[0-9]+$' "a numeric Secret Manager version"

# Remove legacy default Compute Engine SA binding if upgrading from an older deployment
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
DEFAULT_COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud secrets remove-iam-policy-binding "${SECRET_NAME}" \
  --member="serviceAccount:${DEFAULT_COMPUTE_SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="${PROJECT_ID}" \
  --quiet >/dev/null 2>&1 || true

gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="${PROJECT_ID}" \
  --quiet

SECRET_IAM_JSON="$(gcloud secrets get-iam-policy "${SECRET_NAME}" --project="${PROJECT_ID}" --format=json)"
if ! printf '%s' "${SECRET_IAM_JSON}" | jq -e --arg sa "serviceAccount:${RUNTIME_SA}" '
  ([.bindings[]? | select(.role == "roles/secretmanager.secretAccessor") | .members[]?] | unique) as $accessors
  | ($accessors | index($sa)) != null
  and ($accessors | all(. == $sa))
  and ([.bindings[]?.members[]?] | any(. == "allUsers" or . == "allAuthenticatedUsers" or endswith("-compute@developer.gserviceaccount.com")) | not)
' >/dev/null; then
  echo "ERROR: Secret '${SECRET_NAME}' IAM policy is not exclusively scoped to ${RUNTIME_SA}." >&2
  exit 1
fi
echo "==> Secret '${SECRET_NAME}:${SECRET_VERSION}' access verified exclusively for ${RUNTIME_SA}"

# 7. Deploy Cloud Run function with Direct VPC Egress (all-traffic) & pinned secret
gcloud run deploy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --source="${FUNCTION_DIR}" \
  --function="${ENTRY_POINT}" \
  --base-image="python315" \
  --service-account="${RUNTIME_SA}" \
  --no-allow-unauthenticated \
  --network="${VPC_NETWORK}" \
  --subnet="${VPC_SUBNET}" \
  --vpc-egress="all-traffic" \
  --set-secrets="GEMINI_API_KEY=${SECRET_NAME}:${SECRET_VERSION}" \
  --set-env-vars="PYTHONUNBUFFERED=1" \
  --memory="512Mi" \
  --timeout="300s" \
  --concurrency="8" \
  --max-instances="10"

SERVICE_URL="$(gcloud run services describe "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(status.url)')"
validate_regex "SERVICE_URL" "${SERVICE_URL}" '^https://[a-zA-Z0-9._-]+\.run\.app$' "a Cloud Run HTTPS URL"
echo "==> Deployed Cloud Run function URL: ${SERVICE_URL}"

# 8. Create BigQuery dataset in US multi-region (matching bigquery-public-data)
if ! bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${BQ_DATASET}" >/dev/null 2>&1; then
  bq --project_id="${PROJECT_ID}" mk \
    --dataset \
    --location="${BQ_LOCATION}" \
    "${PROJECT_ID}:${BQ_DATASET}"
fi

# 9. Create BigQuery CLOUD_RESOURCE connection in US multi-region
if ! bq show --project_id="${PROJECT_ID}" --location="${BQ_LOCATION}" --connection "${BQ_CONNECTION_ID}" >/dev/null 2>&1; then
  bq mk --connection \
    --location="${BQ_LOCATION}" \
    --project_id="${PROJECT_ID}" \
    --connection_type="CLOUD_RESOURCE" \
    "${BQ_CONNECTION_ID}"
fi

CONNECTION_SA="$(bq show --format=json \
  --project_id="${PROJECT_ID}" \
  --location="${BQ_LOCATION}" \
  --connection "${BQ_CONNECTION_ID}" \
  | jq -r '.cloudResource.serviceAccountId')"
if [[ -z "${CONNECTION_SA}" || "${CONNECTION_SA}" == "null" ]]; then
  echo "ERROR: Failed to resolve BigQuery connection service account ID." >&2
  exit 1
fi
echo "==> BigQuery Connection Service Account: ${CONNECTION_SA}"

# 10. Grant BigQuery connection service account roles/run.invoker and verify private IAM
gcloud run services add-iam-policy-binding "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --member="serviceAccount:${CONNECTION_SA}" \
  --role="roles/run.invoker" \
  --quiet

RUN_IAM_JSON="$(gcloud run services get-iam-policy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format=json)"
if printf '%s' "${RUN_IAM_JSON}" | jq -e '
  [.bindings[]?.members[]?] | any(. == "allUsers" or . == "allAuthenticatedUsers")
' >/dev/null; then
  echo "ERROR: Cloud Run service '${FUNCTION_NAME}' must not allow public/unauthenticated principals." >&2
  exit 1
fi

# 11. Create or replace the BigQuery Remote Function returning JSON
bq query \
  --project_id="${PROJECT_ID}" \
  --location="${BQ_LOCATION}" \
  --use_legacy_sql=false <<SQL
CREATE OR REPLACE FUNCTION \`${PROJECT_ID}.${BQ_DATASET}.evaluate_article\`(
  title STRING,
  body STRING
)
RETURNS JSON
REMOTE WITH CONNECTION \`${PROJECT_ID}.${BQ_LOCATION}.${BQ_CONNECTION_ID}\`
OPTIONS (
  endpoint = '${SERVICE_URL}',
  max_batching_rows = ${MAX_BATCHING_ROWS}
);
SQL

echo "==> BigQuery Remote Function '${PROJECT_ID}.${BQ_DATASET}.evaluate_article' is ready."
echo "==> Security posture verified:"
echo "    - Runtime SA      : ${RUNTIME_SA}"
echo "    - Secret version  : ${SECRET_NAME}:${SECRET_VERSION}"
echo "    - Egress subnet   : ${VPC_SUBNET} (Private Google Access disabled)"
echo "    - Cloud NAT IP    : ${NAT_IP}"
echo "    - API key resource: ${KEY_RESOURCE_NAME} (generativelanguage.googleapis.com @ ${NAT_IP})"
