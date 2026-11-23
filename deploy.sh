#!/usr/bin/env bash
set -euo pipefail
umask 077

# ==============================================================================
# Hardened End-to-End Deployment: Cloud Run Function + BigQuery Remote Function
# ==============================================================================
# Protects the Gemini API key and Cloud Run endpoint through defense-in-depth:
#   1. Dedicated least-privilege Cloud Run service account (blocks default SA).
#   2. Secret Manager numeric version pinning + IAM scoped ONLY to runtime SA.
#   3. GCP API Key restricted via apikeys.googleapis.com to ONLY
#      generativelanguage.googleapis.com (no IP restriction, since Cloud Run
#      routes *.googleapis.com traffic over Google's internal Andromeda fabric).
#   4. Private Cloud Run (--no-allow-unauthenticated) invocable ONLY by the
#      BigQuery Cloud Resource Connection service account.
#
# Modes:
#   Default (verbose/interactive):
#     Explains every planned modification in detail and asks for confirmation
#     before applying each change.
#   --quiet / -q:
#     Applies all modifications automatically without confirmation prompts
#     while logging every modification performed.
#
# Prerequisites:
#   - gcloud CLI authenticated (`gcloud auth login`)
#   - bq CLI, jq, and uv installed
#   - `function/pyproject.toml` and `function/uv.lock` present (NO requirements.txt)
# ==============================================================================

QUIET_MODE="false"
TOTAL_STEPS=10
MODIFICATIONS_LOG=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTION_DIR="${SCRIPT_DIR}/function"

# ------------------------------------------------------------------------------
# CLI Usage & Argument Parsing
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: ./deploy.sh [OPTIONS]

Hardened end-to-end deployment for the Cloud Run function and BigQuery Remote Function.

Modes:
  (default)       Verbose interactive mode: explains each planned modification
                  and asks for confirmation before applying it.
  -q, --quiet     Non-interactive mode: applies all modifications without
                  prompting, while logging everything that was modified.
  -h, --help      Show this help message and exit.

Configurable environment variables:
  PROJECT_ID           Target GCP project ID (default: active gcloud project)
  REGION               Cloud Run region (default: us-central1)
  BQ_LOCATION          BigQuery location (default: US)
  FUNCTION_NAME        Cloud Run service name (default: bbc-news-decisions-rf)
  ENTRY_POINT          Python entry point (default: evaluate_bbc_news)
  BQ_DATASET           BigQuery dataset (default: bbc_news_eval)
  BQ_CONNECTION_ID     BigQuery connection ID (default: gemini-decisions-conn)
  SECRET_NAME          Secret Manager secret name (default: gemini-api-key)
  MAX_BATCHING_ROWS    BigQuery remote function batch size (default: 20)
  RUNTIME_SA_NAME      Dedicated runtime SA ID (default: bbc-news-decisions-sa)
  BUILD_SA_NAME        Dedicated Cloud Build SA ID (default: bbc-news-decisions-build-sa)
  API_KEY_DISPLAY_NAME Managed API key display name (default: bbc-news-decisions-cloudrun-key)
  API_KEY_PROJECT_ID   GCP project owning the API key (default: PROJECT_ID)
  API_KEY_ID           Optional API key UUID for direct lookup
  GEMINI_API_KEY       Optional GCP-managed API key (unset to auto-provision)
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      -q|--quiet)
        QUIET_MODE="true"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: Unknown argument '\''%s'\''. Use --help for usage.\n' "${arg}" >&2
        exit 1
        ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Logging & Interactive Confirmation Helpers
# ------------------------------------------------------------------------------
log_step() {
  local step_num="$1"
  local title="$2"
  printf '\n==============================================================================\n'
  printf '[Step %s/%s] %s\n' "${step_num}" "${TOTAL_STEPS}" "${title}"
  printf '==============================================================================\n'
}

log_info() {
  printf '[INFO] %s\n' "$1"
}

log_unchanged() {
  printf '[UNCHANGED] %s\n' "$1"
}

log_verified() {
  printf '[VERIFIED] %s\n' "$1"
}

log_modified() {
  local msg="$1"
  MODIFICATIONS_LOG+=("${msg}")
  printf '[MODIFIED] %s\n' "${msg}"
}

log_error() {
  printf 'ERROR: %s\n' "$1" >&2
}

# Explain a planned modification and ask for user confirmation unless --quiet.
# Usage: confirm_modification "Title of change" "Detail 1" "Detail 2" ...
confirm_modification() {
  local title="$1"
  shift
  local detail
  local reply=""

  if [[ "${QUIET_MODE}" == "true" ]]; then
    printf '[APPLYING] %s\n' "${title}"
    for detail in "$@"; do
      printf '  - %s\n' "${detail}"
    done
    return 0
  fi

  printf '\nPlanned modification: %s\n' "${title}"
  for detail in "$@"; do
    printf '  - %s\n' "${detail}"
  done

  if ! read -r -p "Confirm and apply this modification? [y/N]: " reply; then
    printf '\n' >&2
    log_error "No confirmation input received. Aborting deployment."
    printf 'Hint: pass --quiet (-q) for non-interactive execution.\n' >&2
    exit 1
  fi

  case "${reply}" in
    [yY]|[yY][eE][sS])
      return 0
      ;;
    *)
      printf '[ABORTED] Modification declined by user: %s\n' "${title}" >&2
      exit 1
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Validation & Configuration
# ------------------------------------------------------------------------------
check_prerequisites() {
  local required_bin
  for required_bin in gcloud bq jq uv; do
    if ! command -v "${required_bin}" >/dev/null 2>&1; then
      log_error "Required CLI '${required_bin}' is not installed or not in PATH."
      exit 1
    fi
  done
}

validate_regex() {
  local var_name="$1"
  local value="$2"
  local pattern="$3"
  local hint="$4"
  if [[ ! "${value}" =~ ${pattern} ]]; then
    log_error "Invalid ${var_name} ('${value}'). Expected ${hint}."
    exit 1
  fi
}

load_and_validate_config() {
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
  BUILD_SA_NAME="${BUILD_SA_NAME:-bbc-news-decisions-build-sa}"

  API_KEY_DISPLAY_NAME="${API_KEY_DISPLAY_NAME:-bbc-news-decisions-cloudrun-key}"
  API_KEY_PROJECT_ID="${API_KEY_PROJECT_ID:-${PROJECT_ID}}"
  API_KEY_ID="${API_KEY_ID:-}"

  if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    log_error "Set PROJECT_ID or run 'gcloud config set project <PROJECT_ID>'."
    exit 1
  fi

  validate_regex "PROJECT_ID" "${PROJECT_ID}" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' "a valid GCP project ID"
  validate_regex "REGION" "${REGION}" '^[a-z]+-[a-z0-9]+[0-9]$' "a GCP region (e.g. us-central1)"
  validate_regex "BQ_LOCATION" "${BQ_LOCATION}" '^[A-Za-z0-9-]+$' "a BigQuery location (e.g. US)"
  validate_regex "FUNCTION_NAME" "${FUNCTION_NAME}" '^[a-z][a-z0-9-]{0,61}[a-z0-9]$' "a valid Cloud Run service name"
  validate_regex "ENTRY_POINT" "${ENTRY_POINT}" '^[A-Za-z_][A-Za-z0-9_]*$' "a Python identifier"
  validate_regex "BQ_DATASET" "${BQ_DATASET}" '^[A-Za-z0-9_]+$' "a BigQuery dataset identifier"
  if [[ ${#BQ_DATASET} -gt 1024 ]]; then
    log_error "Invalid BQ_DATASET ('${BQ_DATASET}'). Expected at most 1024 characters."
    exit 1
  fi
  validate_regex "BQ_CONNECTION_ID" "${BQ_CONNECTION_ID}" '^[A-Za-z0-9_-]+$' "a BigQuery connection ID"
  if [[ ${#BQ_CONNECTION_ID} -gt 1024 ]]; then
    log_error "Invalid BQ_CONNECTION_ID ('${BQ_CONNECTION_ID}'). Expected at most 1024 characters."
    exit 1
  fi
  validate_regex "SECRET_NAME" "${SECRET_NAME}" '^[A-Za-z0-9_-]{1,255}$' "a Secret Manager secret name"
  validate_regex "MAX_BATCHING_ROWS" "${MAX_BATCHING_ROWS}" '^[1-9][0-9]{0,2}$' "an integer between 1 and 999"
  validate_regex "RUNTIME_SA_NAME" "${RUNTIME_SA_NAME}" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' "a service account ID (6-30 chars)"
  validate_regex "BUILD_SA_NAME" "${BUILD_SA_NAME}" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' "a service account ID (6-30 chars)"
  validate_regex "API_KEY_PROJECT_ID" "${API_KEY_PROJECT_ID}" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' "a valid GCP project ID"
  if [[ -n "${API_KEY_ID}" ]]; then
    validate_regex "API_KEY_ID" "${API_KEY_ID}" '^[a-zA-Z0-9-]+$' "an alphanumeric/hyphen API key ID"
  fi

  RUNTIME_SA="${RUNTIME_SA:-${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"
  if [[ "${RUNTIME_SA}" == *-compute@developer.gserviceaccount.com ]]; then
    log_error "Refusing to use the shared Compute Engine default SA (${RUNTIME_SA}). Use a dedicated Cloud Run SA."
    exit 1
  fi
  validate_regex "RUNTIME_SA" "${RUNTIME_SA}" '^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$' "a project service account email"

  BUILD_SA="${BUILD_SA:-${BUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"
  if [[ "${BUILD_SA}" == *-compute@developer.gserviceaccount.com ]]; then
    log_error "Refusing to use the shared Compute Engine default SA (${BUILD_SA}) for Cloud Build. Use a dedicated build SA."
    exit 1
  fi
  if [[ "${BUILD_SA}" == "${RUNTIME_SA}" ]]; then
    log_error "BUILD_SA (${BUILD_SA}) must be distinct from RUNTIME_SA (${RUNTIME_SA}) so runtime stays zero-role and build has no Secret Manager access."
    exit 1
  fi
  validate_regex "BUILD_SA" "${BUILD_SA}" '^[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com$' "a project service account email"

  if [[ "${QUIET_MODE}" == "true" ]]; then
    log_info "Starting deployment in QUIET mode (no confirmation prompts; all modifications logged)."
  else
    log_info "Starting deployment in VERBOSE interactive mode (confirmation required for every modification)."
  fi
  log_info "Target: project=${PROJECT_ID}, region=${REGION}, bq_location=${BQ_LOCATION}, function=${FUNCTION_NAME}"
}

# ------------------------------------------------------------------------------
# Step 1: Verify uv lockfile is in sync and no requirements.txt exists
# ------------------------------------------------------------------------------
step_verify_lockfile() {
  log_step 1 "Verify Python dependency lockfile (read-only)"
  log_info "Checking uv.lock consistency in ${FUNCTION_DIR}..."
  uv lock --check --project "${FUNCTION_DIR}"
  if [[ -f "${FUNCTION_DIR}/requirements.txt" ]]; then
    log_error "Remove ${FUNCTION_DIR}/requirements.txt so Cloud Run's Python buildpack uses uv."
    exit 1
  fi
  log_verified "uv.lock is in sync and no requirements.txt is present."
}

# ------------------------------------------------------------------------------
# Step 2: Enable required Google Cloud APIs
# ------------------------------------------------------------------------------
step_enable_apis() {
  log_step 2 "Enable required Google Cloud APIs"

  local required_apis=(
    run.googleapis.com
    cloudbuild.googleapis.com
    artifactregistry.googleapis.com
    bigquery.googleapis.com
    bigqueryconnection.googleapis.com
    secretmanager.googleapis.com
    iam.googleapis.com
    apikeys.googleapis.com
    generativelanguage.googleapis.com
  )

  local enabled_apis
  enabled_apis="$(gcloud services list --enabled --project="${PROJECT_ID}" --format='value(config.name)' 2>/dev/null || true)"

  local missing_apis=()
  local api
  for api in "${required_apis[@]}"; do
    if ! printf '%s\n' "${enabled_apis}" | grep -Fqx -- "${api}"; then
      missing_apis+=("${api}")
    fi
  done

  if [[ ${#missing_apis[@]} -gt 0 ]]; then
    local detail_lines=("Project: ${PROJECT_ID}")
    for api in "${missing_apis[@]}"; do
      detail_lines+=("Enable API: ${api}")
    done

    confirm_modification \
      "Enable ${#missing_apis[@]} required Google Cloud API(s) in project '${PROJECT_ID}'" \
      "${detail_lines[@]}"

    gcloud services enable "${missing_apis[@]}" --project="${PROJECT_ID}"
    log_modified "Enabled APIs in '${PROJECT_ID}': ${missing_apis[*]}"
  else
    log_unchanged "All ${#required_apis[@]} required Google Cloud APIs are already enabled in '${PROJECT_ID}'."
  fi

  if [[ "${API_KEY_PROJECT_ID}" != "${PROJECT_ID}" ]]; then
    local key_project_enabled
    key_project_enabled="$(gcloud services list --enabled --project="${API_KEY_PROJECT_ID}" --format='value(config.name)' 2>/dev/null || true)"
    if ! printf '%s\n' "${key_project_enabled}" | grep -Fqx -- "apikeys.googleapis.com"; then
      confirm_modification \
        "Enable apikeys.googleapis.com in API key project '${API_KEY_PROJECT_ID}'" \
        "Project: ${API_KEY_PROJECT_ID}" \
        "Enable API: apikeys.googleapis.com"

      gcloud services enable apikeys.googleapis.com --project="${API_KEY_PROJECT_ID}"
      log_modified "Enabled apikeys.googleapis.com in '${API_KEY_PROJECT_ID}'"
    else
      log_unchanged "apikeys.googleapis.com is already enabled in '${API_KEY_PROJECT_ID}'."
    fi
  fi
}

# ------------------------------------------------------------------------------
# Step 3: Ensure dedicated Cloud Run runtime and build service accounts exist
# ------------------------------------------------------------------------------
step_ensure_runtime_sa() {
  log_step 3 "Ensure dedicated Cloud Run runtime and build service accounts"

  if ! gcloud iam service-accounts describe "${RUNTIME_SA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    local sa_account_id="${RUNTIME_SA%%@*}"
    confirm_modification \
      "Create dedicated Cloud Run runtime service account '${RUNTIME_SA}'" \
      "Project: ${PROJECT_ID}" \
      "Account ID: ${sa_account_id}" \
      "Display name: BBC News Decisions Cloud Run SA" \
      "Description: Dedicated least-privilege runtime identity for ${FUNCTION_NAME}" \
      "Project-level IAM roles granted: none (zero project-level roles)"

    gcloud iam service-accounts create "${sa_account_id}" \
      --project="${PROJECT_ID}" \
      --display-name="BBC News Decisions Cloud Run SA" \
      --description="Dedicated least-privilege runtime identity for ${FUNCTION_NAME}"
    log_modified "Created dedicated Cloud Run runtime service account '${RUNTIME_SA}'"
  else
    log_unchanged "Dedicated Cloud Run runtime service account '${RUNTIME_SA}' already exists."
  fi

  local build_sa_changed="false"
  if ! gcloud iam service-accounts describe "${BUILD_SA}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    local build_sa_account_id="${BUILD_SA%%@*}"
    confirm_modification \
      "Create dedicated Cloud Build service account '${BUILD_SA}'" \
      "Project: ${PROJECT_ID}" \
      "Account ID: ${build_sa_account_id}" \
      "Display name: BBC News Decisions Cloud Build SA" \
      "Description: Dedicated least-privilege build identity for ${FUNCTION_NAME} source deployments" \
      "Secret Manager access: none"

    gcloud iam service-accounts create "${build_sa_account_id}" \
      --project="${PROJECT_ID}" \
      --display-name="BBC News Decisions Cloud Build SA" \
      --description="Dedicated least-privilege build identity for ${FUNCTION_NAME} source deployments"
    log_modified "Created dedicated Cloud Build service account '${BUILD_SA}'"
    build_sa_changed="true"
  else
    log_unchanged "Dedicated Cloud Build service account '${BUILD_SA}' already exists."
  fi

  local required_build_roles=(
    roles/run.builder
    roles/cloudbuild.builds.builder
    roles/artifactregistry.writer
    roles/logging.logWriter
    roles/storage.objectViewer
    roles/serviceusage.serviceUsageConsumer
  )

  local project_iam_json
  project_iam_json="$(gcloud projects get-iam-policy "${PROJECT_ID}" --format=json)"

  local missing_build_roles=()
  local role
  for role in "${required_build_roles[@]}"; do
    if ! printf '%s' "${project_iam_json}" | jq -e \
      --arg role "${role}" \
      --arg member "serviceAccount:${BUILD_SA}" '
      [.bindings[]? | select(.role == $role) | .members[]?] | index($member) != null
    ' >/dev/null; then
      missing_build_roles+=("${role}")
    fi
  done

  if [[ ${#missing_build_roles[@]} -gt 0 ]]; then
    local role_details=(
      "Project: ${PROJECT_ID}"
      "Member: serviceAccount:${BUILD_SA}"
    )
    for role in "${missing_build_roles[@]}"; do
      role_details+=("Grant role: ${role}")
    done

    confirm_modification \
      "Grant ${#missing_build_roles[@]} Cloud Run build IAM role(s) to '${BUILD_SA}'" \
      "${role_details[@]}"

    for role in "${missing_build_roles[@]}"; do
      gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${BUILD_SA}" \
        --role="${role}" \
        --condition=None \
        --quiet >/dev/null
    done
    log_modified "Granted build IAM roles on '${PROJECT_ID}' to '${BUILD_SA}': ${missing_build_roles[*]}"
    build_sa_changed="true"
  else
    log_unchanged "Cloud Build service account '${BUILD_SA}' already holds all required build IAM roles."
  fi

  if [[ "${build_sa_changed}" == "true" ]]; then
    log_info "Waiting 15s for Cloud Build service account IAM propagation..."
    sleep 15
  fi
}

# ------------------------------------------------------------------------------
# Step 4: Provision or restrict Gemini API key to generativelanguage.googleapis.com
# ------------------------------------------------------------------------------
api_key_is_strictly_restricted() {
  local key_resource="$1"
  local key_desc_json
  key_desc_json="$(gcloud services api-keys describe "${key_resource}" --format=json)"
  printf '%s' "${key_desc_json}" | jq -e '
    (.restrictions.apiTargets | length == 1 and .[0].service == "generativelanguage.googleapis.com")
    and (.restrictions.serverKeyRestrictions == null)
  ' >/dev/null
}

step_configure_api_key() {
  log_step 4 "Provision and restrict Gemini API key"
  set +x

  KEY_RESOURCE_NAME=""
  EFFECTIVE_API_KEY=""

  if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    log_info "Mode: Managed Key (GEMINI_API_KEY unset) in project '${API_KEY_PROJECT_ID}'."
    if [[ -n "${API_KEY_ID}" ]]; then
      KEY_RESOURCE_NAME="projects/${API_KEY_PROJECT_ID}/locations/global/keys/${API_KEY_ID}"
    else
      KEY_RESOURCE_NAME="$(gcloud services api-keys list \
        --project="${API_KEY_PROJECT_ID}" \
        --filter="displayName=\"${API_KEY_DISPLAY_NAME}\"" \
        --format='value(name)' | head -n 1 || true)"
    fi

    if [[ -z "${KEY_RESOURCE_NAME}" ]]; then
      confirm_modification \
        "Create restricted Gemini API key '${API_KEY_DISPLAY_NAME}'" \
        "Project: ${API_KEY_PROJECT_ID}" \
        "Display name: ${API_KEY_DISPLAY_NAME}" \
        "API target restriction: generativelanguage.googleapis.com only" \
        "IP restriction: none (Cloud Run uses Google's internal Andromeda fabric)"

      gcloud services api-keys create \
        --project="${API_KEY_PROJECT_ID}" \
        --display-name="${API_KEY_DISPLAY_NAME}" \
        --api-target="service=generativelanguage.googleapis.com" \
        --quiet >/dev/null

      KEY_RESOURCE_NAME="$(gcloud services api-keys list \
        --project="${API_KEY_PROJECT_ID}" \
        --filter="displayName=\"${API_KEY_DISPLAY_NAME}\"" \
        --format='value(name)' | head -n 1 || true)"
      if [[ -z "${KEY_RESOURCE_NAME}" ]]; then
        log_error "Failed to resolve newly created API key resource '${API_KEY_DISPLAY_NAME}'."
        exit 1
      fi
      log_modified "Created restricted API key '${KEY_RESOURCE_NAME}' (generativelanguage.googleapis.com only)"
    else
      if api_key_is_strictly_restricted "${KEY_RESOURCE_NAME}"; then
        log_unchanged "API key '${KEY_RESOURCE_NAME}' is already restricted strictly to generativelanguage.googleapis.com."
      else
        confirm_modification \
          "Update restrictions on existing API key '${KEY_RESOURCE_NAME}'" \
          "Resource: ${KEY_RESOURCE_NAME}" \
          "Action 1: Clear existing API/IP restrictions" \
          "Action 2: Restrict API targets strictly to generativelanguage.googleapis.com"

        gcloud services api-keys update "${KEY_RESOURCE_NAME}" \
          --clear-restrictions \
          --quiet >/dev/null
        gcloud services api-keys update "${KEY_RESOURCE_NAME}" \
          --api-target="service=generativelanguage.googleapis.com" \
          --quiet >/dev/null
        log_modified "Updated restrictions on API key '${KEY_RESOURCE_NAME}' (generativelanguage.googleapis.com only)"
      fi
    fi

    EFFECTIVE_API_KEY="$(gcloud services api-keys get-key-string "${KEY_RESOURCE_NAME}" --format='value(keyString)')"
  else
    log_info "Mode: Caller-Provided Key (fail-closed lookup in project '${API_KEY_PROJECT_ID}')."
    if [[ -n "${API_KEY_ID}" ]]; then
      local candidate_name="projects/${API_KEY_PROJECT_ID}/locations/global/keys/${API_KEY_ID}"
      local candidate_str
      candidate_str="$(gcloud services api-keys get-key-string "${candidate_name}" --format='value(keyString)' 2>/dev/null || true)"
      if [[ "${candidate_str}" == "${GEMINI_API_KEY}" ]]; then
        KEY_RESOURCE_NAME="${candidate_name}"
      fi
      unset candidate_str
    else
      local candidate_name
      local candidate_str
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
      log_error "Provided GEMINI_API_KEY was not found in project '${API_KEY_PROJECT_ID}'."
      printf '       Fail-closed policy refuses to deploy an unrestricted or unmanaged API key.\n' >&2
      printf '       Unset GEMINI_API_KEY to let deploy.sh create a restricted key automatically,\n' >&2
      printf '       or set API_KEY_PROJECT_ID (and optionally API_KEY_ID) to the key'\''s owning GCP project.\n' >&2
      exit 1
    fi

    if api_key_is_strictly_restricted "${KEY_RESOURCE_NAME}"; then
      log_unchanged "Provided API key '${KEY_RESOURCE_NAME}' is already restricted strictly to generativelanguage.googleapis.com."
    else
      confirm_modification \
        "Enforce API target restriction on provided API key '${KEY_RESOURCE_NAME}'" \
        "Resource: ${KEY_RESOURCE_NAME}" \
        "Action 1: Clear existing API/IP restrictions" \
        "Action 2: Restrict API targets strictly to generativelanguage.googleapis.com"

      gcloud services api-keys update "${KEY_RESOURCE_NAME}" \
        --clear-restrictions \
        --quiet >/dev/null
      gcloud services api-keys update "${KEY_RESOURCE_NAME}" \
        --api-target="service=generativelanguage.googleapis.com" \
        --quiet >/dev/null
      log_modified "Enforced generativelanguage.googleapis.com-only restriction on '${KEY_RESOURCE_NAME}'"
    fi

    EFFECTIVE_API_KEY="${GEMINI_API_KEY}"
  fi

  if [[ -z "${EFFECTIVE_API_KEY}" ]]; then
    log_error "Resolved Gemini API key string is empty."
    exit 1
  fi

  # Mandatory verification gate on API key restrictions (API-only, no IP restriction)
  if ! api_key_is_strictly_restricted "${KEY_RESOURCE_NAME}"; then
    log_error "API key '${KEY_RESOURCE_NAME}' failed restriction verification (expected ONLY generativelanguage.googleapis.com without IP restrictions)."
    exit 1
  fi
  log_verified "API key '${KEY_RESOURCE_NAME}' is restricted strictly to generativelanguage.googleapis.com."
}

# ------------------------------------------------------------------------------
# Step 5: Store Gemini API key in Secret Manager, pin version, lock IAM
# ------------------------------------------------------------------------------
step_configure_secret() {
  log_step 5 "Configure Secret Manager secret, version pinning, and exclusive IAM"
  set +x

  if ! gcloud secrets describe "${SECRET_NAME}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    confirm_modification \
      "Create Secret Manager secret '${SECRET_NAME}' with initial API key version" \
      "Project: ${PROJECT_ID}" \
      "Secret name: ${SECRET_NAME}" \
      "Replication policy: automatic" \
      "Payload: resolved Gemini API key (value redacted)"

    printf '%s' "${EFFECTIVE_API_KEY}" | gcloud secrets create "${SECRET_NAME}" \
      --replication-policy="automatic" \
      --data-file=- \
      --project="${PROJECT_ID}" \
      --quiet
    log_modified "Created Secret Manager secret '${SECRET_NAME}' with initial version"
  else
    local current_secret_val
    current_secret_val="$(gcloud secrets versions access latest --secret="${SECRET_NAME}" --project="${PROJECT_ID}" 2>/dev/null || true)"
    if [[ "${current_secret_val}" != "${EFFECTIVE_API_KEY}" ]]; then
      confirm_modification \
        "Add a new version to Secret Manager secret '${SECRET_NAME}'" \
        "Project: ${PROJECT_ID}" \
        "Secret name: ${SECRET_NAME}" \
        "Reason: latest stored value differs from resolved Gemini API key (value redacted)"

      printf '%s' "${EFFECTIVE_API_KEY}" | gcloud secrets versions add "${SECRET_NAME}" \
        --data-file=- \
        --project="${PROJECT_ID}" \
        --quiet
      log_modified "Added new secret version to '${SECRET_NAME}'"
    else
      log_unchanged "Secret '${SECRET_NAME}' latest version already matches the resolved API key."
    fi
    unset current_secret_val
  fi
  unset EFFECTIVE_API_KEY

  local latest_version_name
  latest_version_name="$(gcloud secrets versions list "${SECRET_NAME}" \
    --project="${PROJECT_ID}" \
    --filter="state=ENABLED" \
    --sort-by="~createTime" \
    --limit=1 \
    --format='value(name)')"
  SECRET_VERSION="${latest_version_name##*/}"
  validate_regex "SECRET_VERSION" "${SECRET_VERSION}" '^[0-9]+$' "a numeric Secret Manager version"
  log_info "Pinned secret version: ${SECRET_NAME}:${SECRET_VERSION}"

  local project_number
  project_number="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  local default_compute_sa="${project_number}-compute@developer.gserviceaccount.com"

  local secret_iam_json
  secret_iam_json="$(gcloud secrets get-iam-policy "${SECRET_NAME}" --project="${PROJECT_ID}" --format=json)"

  # Remove legacy default Compute Engine SA binding if present
  if printf '%s' "${secret_iam_json}" | jq -e --arg sa "serviceAccount:${default_compute_sa}" '
    [.bindings[]? | select(.role == "roles/secretmanager.secretAccessor") | .members[]?] | index($sa) != null
  ' >/dev/null; then
    confirm_modification \
      "Remove legacy Compute Engine default SA access from secret '${SECRET_NAME}'" \
      "Project: ${PROJECT_ID}" \
      "Secret: ${SECRET_NAME}" \
      "Remove member: serviceAccount:${default_compute_sa}" \
      "Role: roles/secretmanager.secretAccessor"

    gcloud secrets remove-iam-policy-binding "${SECRET_NAME}" \
      --member="serviceAccount:${default_compute_sa}" \
      --role="roles/secretmanager.secretAccessor" \
      --project="${PROJECT_ID}" \
      --quiet >/dev/null
    log_modified "Removed roles/secretmanager.secretAccessor on '${SECRET_NAME}' from '${default_compute_sa}'"
  fi

  # Ensure dedicated runtime SA has roles/secretmanager.secretAccessor
  if ! printf '%s' "${secret_iam_json}" | jq -e --arg sa "serviceAccount:${RUNTIME_SA}" '
    [.bindings[]? | select(.role == "roles/secretmanager.secretAccessor") | .members[]?] | index($sa) != null
  ' >/dev/null; then
    confirm_modification \
      "Grant Secret Manager accessor role on '${SECRET_NAME}' to '${RUNTIME_SA}'" \
      "Project: ${PROJECT_ID}" \
      "Secret: ${SECRET_NAME}" \
      "Add member: serviceAccount:${RUNTIME_SA}" \
      "Role: roles/secretmanager.secretAccessor"

    gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
      --member="serviceAccount:${RUNTIME_SA}" \
      --role="roles/secretmanager.secretAccessor" \
      --project="${PROJECT_ID}" \
      --quiet
    log_modified "Granted roles/secretmanager.secretAccessor on '${SECRET_NAME}' to '${RUNTIME_SA}'"
  else
    log_unchanged "Secret '${SECRET_NAME}' already grants roles/secretmanager.secretAccessor to '${RUNTIME_SA}'."
  fi

  secret_iam_json="$(gcloud secrets get-iam-policy "${SECRET_NAME}" --project="${PROJECT_ID}" --format=json)"
  if ! printf '%s' "${secret_iam_json}" | jq -e --arg sa "serviceAccount:${RUNTIME_SA}" '
    ([.bindings[]? | select(.role == "roles/secretmanager.secretAccessor") | .members[]?] | unique) as $accessors
    | ($accessors | index($sa)) != null
    and ($accessors | all(. == $sa))
    and ([.bindings[]?.members[]?] | any(. == "allUsers" or . == "allAuthenticatedUsers" or endswith("-compute@developer.gserviceaccount.com")) | not)
  ' >/dev/null; then
    log_error "Secret '${SECRET_NAME}' IAM policy is not exclusively scoped to ${RUNTIME_SA}."
    exit 1
  fi
  log_verified "Secret '${SECRET_NAME}:${SECRET_VERSION}' access verified exclusively for ${RUNTIME_SA}."
}

# ------------------------------------------------------------------------------
# Step 6: Deploy Cloud Run function with dedicated SA, pinned secret, private IAM
# ------------------------------------------------------------------------------
step_deploy_cloud_run() {
  log_step 6 "Deploy private Cloud Run function"

  confirm_modification \
    "Deploy Cloud Run function '${FUNCTION_NAME}'" \
    "Project: ${PROJECT_ID}" \
    "Region: ${REGION}" \
    "Source: ${FUNCTION_DIR}" \
    "Entry point: ${ENTRY_POINT} (base-image: python315)" \
    "Runtime service account: ${RUNTIME_SA}" \
    "Build service account: ${BUILD_SA}" \
    "Access control: --no-allow-unauthenticated (private)" \
    "Secret mount: GEMINI_API_KEY=${SECRET_NAME}:${SECRET_VERSION}" \
    "Env vars: PYTHONUNBUFFERED=1" \
    "Resources: memory=512Mi, timeout=300s, concurrency=8, max-instances=10"

  gcloud run deploy "${FUNCTION_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --source="${FUNCTION_DIR}" \
    --function="${ENTRY_POINT}" \
    --base-image="python315" \
    --service-account="${RUNTIME_SA}" \
    --build-service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA}" \
    --no-allow-unauthenticated \
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
  log_modified "Deployed Cloud Run function '${FUNCTION_NAME}' (${SERVICE_URL})"
}

# ------------------------------------------------------------------------------
# Step 7: Create BigQuery dataset
# ------------------------------------------------------------------------------
step_ensure_bq_dataset() {
  log_step 7 "Ensure BigQuery dataset exists"

  if ! bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${BQ_DATASET}" >/dev/null 2>&1; then
    confirm_modification \
      "Create BigQuery dataset '${PROJECT_ID}:${BQ_DATASET}'" \
      "Project: ${PROJECT_ID}" \
      "Dataset: ${BQ_DATASET}" \
      "Location: ${BQ_LOCATION}"

    bq --project_id="${PROJECT_ID}" mk \
      --dataset \
      --location="${BQ_LOCATION}" \
      "${PROJECT_ID}:${BQ_DATASET}"
    log_modified "Created BigQuery dataset '${PROJECT_ID}:${BQ_DATASET}' in location '${BQ_LOCATION}'"
  else
    log_unchanged "BigQuery dataset '${PROJECT_ID}:${BQ_DATASET}' already exists."
  fi
}

# ------------------------------------------------------------------------------
# Step 8: Create BigQuery CLOUD_RESOURCE connection
# ------------------------------------------------------------------------------
step_ensure_bq_connection() {
  log_step 8 "Ensure BigQuery CLOUD_RESOURCE connection exists"

  if ! bq show --project_id="${PROJECT_ID}" --location="${BQ_LOCATION}" --connection "${BQ_CONNECTION_ID}" >/dev/null 2>&1; then
    confirm_modification \
      "Create BigQuery CLOUD_RESOURCE connection '${BQ_CONNECTION_ID}'" \
      "Project: ${PROJECT_ID}" \
      "Location: ${BQ_LOCATION}" \
      "Connection ID: ${BQ_CONNECTION_ID}" \
      "Connection type: CLOUD_RESOURCE"

    bq mk --connection \
      --location="${BQ_LOCATION}" \
      --project_id="${PROJECT_ID}" \
      --connection_type="CLOUD_RESOURCE" \
      "${BQ_CONNECTION_ID}"
    log_modified "Created BigQuery CLOUD_RESOURCE connection '${BQ_CONNECTION_ID}' in '${BQ_LOCATION}'"
  else
    log_unchanged "BigQuery connection '${BQ_CONNECTION_ID}' already exists in '${BQ_LOCATION}'."
  fi

  CONNECTION_SA="$(bq show --format=json \
    --project_id="${PROJECT_ID}" \
    --location="${BQ_LOCATION}" \
    --connection "${BQ_CONNECTION_ID}" \
    | jq -r '.cloudResource.serviceAccountId')"
  if [[ -z "${CONNECTION_SA}" || "${CONNECTION_SA}" == "null" ]]; then
    log_error "Failed to resolve BigQuery connection service account ID."
    exit 1
  fi
  log_info "BigQuery Connection Service Account: ${CONNECTION_SA}"
}

# ------------------------------------------------------------------------------
# Step 9: Grant BigQuery connection SA roles/run.invoker and verify private IAM
# ------------------------------------------------------------------------------
step_grant_run_invoker() {
  log_step 9 "Grant Cloud Run invoker role to BigQuery connection and verify private IAM"

  local run_iam_json
  run_iam_json="$(gcloud run services get-iam-policy "${FUNCTION_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format=json)"

  if ! printf '%s' "${run_iam_json}" | jq -e --arg sa "serviceAccount:${CONNECTION_SA}" '
    [.bindings[]? | select(.role == "roles/run.invoker") | .members[]?] | index($sa) != null
  ' >/dev/null; then
    confirm_modification \
      "Grant roles/run.invoker on Cloud Run service '${FUNCTION_NAME}'" \
      "Project: ${PROJECT_ID}" \
      "Region: ${REGION}" \
      "Service: ${FUNCTION_NAME}" \
      "Add member: serviceAccount:${CONNECTION_SA}" \
      "Role: roles/run.invoker"

    gcloud run services add-iam-policy-binding "${FUNCTION_NAME}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --member="serviceAccount:${CONNECTION_SA}" \
      --role="roles/run.invoker" \
      --quiet
    log_modified "Granted roles/run.invoker on '${FUNCTION_NAME}' to '${CONNECTION_SA}'"

    run_iam_json="$(gcloud run services get-iam-policy "${FUNCTION_NAME}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --format=json)"
  else
    log_unchanged "Cloud Run service '${FUNCTION_NAME}' already grants roles/run.invoker to '${CONNECTION_SA}'."
  fi

  if printf '%s' "${run_iam_json}" | jq -e '
    [.bindings[]?.members[]?] | any(. == "allUsers" or . == "allAuthenticatedUsers")
  ' >/dev/null; then
    log_error "Cloud Run service '${FUNCTION_NAME}' must not allow public/unauthenticated principals."
    exit 1
  fi
  log_verified "Cloud Run service '${FUNCTION_NAME}' IAM disallows public/unauthenticated principals."
}

# ------------------------------------------------------------------------------
# Step 10: Create or replace the BigQuery Remote Function
# ------------------------------------------------------------------------------
step_deploy_bq_remote_function() {
  log_step 10 "Create or replace BigQuery Remote Function"

  confirm_modification \
    "Create or replace BigQuery Remote Function '${PROJECT_ID}.${BQ_DATASET}.evaluate_article'" \
    "Project: ${PROJECT_ID}" \
    "Location: ${BQ_LOCATION}" \
    "Function: ${PROJECT_ID}.${BQ_DATASET}.evaluate_article(title STRING, body STRING) RETURNS JSON" \
    "Connection: ${PROJECT_ID}.${BQ_LOCATION}.${BQ_CONNECTION_ID}" \
    "Endpoint: ${SERVICE_URL}" \
    "max_batching_rows: ${MAX_BATCHING_ROWS}"

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
  log_modified "Created/replaced BigQuery Remote Function '${PROJECT_ID}.${BQ_DATASET}.evaluate_article'"
}

# ------------------------------------------------------------------------------
# Deployment Summary
# ------------------------------------------------------------------------------
print_summary() {
  printf '\n==============================================================================\n'
  printf 'Deployment Complete\n'
  printf '==============================================================================\n'
  printf 'BigQuery Remote Function : %s.%s.evaluate_article\n' "${PROJECT_ID}" "${BQ_DATASET}"
  printf 'Cloud Run URL            : %s\n' "${SERVICE_URL}"
  printf 'Security posture verified:\n'
  printf '  - Runtime SA      : %s\n' "${RUNTIME_SA}"
  printf '  - Build SA        : %s\n' "${BUILD_SA}"
  printf '  - Secret version  : %s:%s\n' "${SECRET_NAME}" "${SECRET_VERSION}"
  printf '  - API key resource: %s (generativelanguage.googleapis.com only)\n' "${KEY_RESOURCE_NAME}"

  printf '\nModifications applied (%d):\n' "${#MODIFICATIONS_LOG[@]}"
  if [[ ${#MODIFICATIONS_LOG[@]} -eq 0 ]]; then
    printf '  (none — all resources were already up to date)\n'
  else
    local item
    for item in "${MODIFICATIONS_LOG[@]}"; do
      printf '  * %s\n' "${item}"
    done
  fi
  printf '\nNext: ./dataform.sh\n'
}

main() {
  parse_args "$@"
  check_prerequisites
  load_and_validate_config

  step_verify_lockfile
  step_enable_apis
  step_ensure_runtime_sa
  step_configure_api_key
  step_configure_secret
  step_deploy_cloud_run
  step_ensure_bq_dataset
  step_ensure_bq_connection
  step_grant_run_invoker
  step_deploy_bq_remote_function

  print_summary
}

main "$@"
