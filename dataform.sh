#!/usr/bin/env bash
set -euo pipefail
umask 077

# ==============================================================================
# Google Cloud Dataform Environment & Repository Setup
# ==============================================================================
# Run this AFTER ./deploy.sh. It provisions and configures the Google Cloud
# Dataform environment for this project:
#   1. Enables the Dataform API (dataform.googleapis.com).
#   2. Resolves the deployed Cloud Run endpoint URL (or uses CLOUD_RUN_URL).
#   3. Creates (or updates) the Dataform repository with defaultProject
#      workspace compilation overrides (and optional external Git remote).
#   4. Grants required BigQuery & Connection IAM roles to the Dataform
#      service agent (and Secret Manager accessor if using a Git token secret).
#   5. Commits definitions/ and a rendered workflow_settings.yaml (with
#      defaultProject and vars.cloudRunEndpoint populated) to the Dataform
#      repository while keeping local workflow_settings.yaml clean.
#   6. Ensures a development workspace exists in Dataform Studio.
#   7. Creates (or updates) the Dataform release config with codeCompilationConfig
#      overrides for defaultDatabase (defaultProject) and vars.cloudRunEndpoint.
#   8. Compiles the release config to verify zero compilation errors.
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
#   - curl, jq, and base64 installed
#   - ./deploy.sh completed (or CLOUD_RUN_URL provided explicitly)
# ==============================================================================

QUIET_MODE="false"
TOTAL_STEPS=8
MODIFICATIONS_LOG=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFINITIONS_DIR="${SCRIPT_DIR}/definitions"
WORKFLOW_SETTINGS_FILE="${SCRIPT_DIR}/workflow_settings.yaml"
DATAFORM_API_BASE="https://dataform.googleapis.com/v1"

# ------------------------------------------------------------------------------
# CLI Usage & Argument Parsing
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: ./dataform.sh [OPTIONS]

Set up and configure the Google Cloud Dataform environment, repository,
defaultProject, and cloudRunEndpoint for google-decision-api-demo.

Modes:
  (default)       Verbose interactive mode: explains each planned modification
                  and asks for confirmation before applying it.
  -q, --quiet     Non-interactive mode: applies all modifications without
                  prompting, while logging everything that was modified.
  -h, --help      Show this help message and exit.

Configurable environment variables:
  PROJECT_ID                       Target GCP project ID (default: active gcloud project)
  REGION                           Cloud Run service region (default: us-central1)
  DATAFORM_LOCATION                Dataform repository region (default: REGION)
  BQ_LOCATION                      BigQuery location (default: US)
  FUNCTION_NAME                    Cloud Run service name (default: bbc-news-decisions-rf)
  CLOUD_RUN_URL                    Cloud Run HTTPS URL (default: auto-discovered from FUNCTION_NAME)
  BQ_DATASET                       BigQuery default dataset (default: bbc_news_eval)
  BQ_ASSERTION_DATASET             BigQuery assertions dataset (default: <BQ_DATASET>_assertions)
  BQ_CONNECTION_ID                 BigQuery connection ID (default: gemini-decisions-conn)
  MAX_BATCHING_ROWS                BigQuery remote function batch size (default: 20)
  DATAFORM_REPO_ID                 Dataform repository ID (default: google-decision-api-demo)
  DATAFORM_REPO_DISPLAY_NAME       Dataform repository display name (default: Google Decision API Demo)
  DATAFORM_WORKSPACE_ID            Dataform development workspace ID (default: dev)
  DATAFORM_RELEASE_CONFIG_ID       Dataform release config ID (default: production)
  DATAFORM_GIT_COMMITISH           Branch/tag/SHA for release config (default: main)
  DATAFORM_GIT_URL                 Optional external Git HTTPS remote URL (unset for Dataform-hosted repo)
  DATAFORM_GIT_TOKEN_SECRET_VERSION Optional Secret Manager version for private Git remote auth
                                   (format: projects/<project>/secrets/<secret>/versions/<version>)
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
    log_error "No confirmation input received. Aborting Dataform setup."
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
  for required_bin in gcloud curl jq base64; do
    if ! command -v "${required_bin}" >/dev/null 2>&1; then
      log_error "Required CLI '${required_bin}' is not installed or not in PATH."
      exit 1
    fi
  done

  if [[ ! -f "${WORKFLOW_SETTINGS_FILE}" ]]; then
    log_error "Missing ${WORKFLOW_SETTINGS_FILE}."
    exit 1
  fi

  if [[ ! -d "${DEFINITIONS_DIR}" ]]; then
    log_error "Missing ${DEFINITIONS_DIR} directory."
    exit 1
  fi
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
  DATAFORM_LOCATION="${DATAFORM_LOCATION:-${REGION}}"
  BQ_LOCATION="${BQ_LOCATION:-US}"
  FUNCTION_NAME="${FUNCTION_NAME:-bbc-news-decisions-rf}"
  CLOUD_RUN_URL="${CLOUD_RUN_URL:-}"
  BQ_DATASET="${BQ_DATASET:-bbc_news_eval}"
  BQ_ASSERTION_DATASET="${BQ_ASSERTION_DATASET:-${BQ_DATASET}_assertions}"
  BQ_CONNECTION_ID="${BQ_CONNECTION_ID:-gemini-decisions-conn}"
  MAX_BATCHING_ROWS="${MAX_BATCHING_ROWS:-20}"

  DATAFORM_REPO_ID="${DATAFORM_REPO_ID:-google-decision-api-demo}"
  DATAFORM_REPO_DISPLAY_NAME="${DATAFORM_REPO_DISPLAY_NAME:-Google Decision API Demo}"
  DATAFORM_WORKSPACE_ID="${DATAFORM_WORKSPACE_ID:-dev}"
  DATAFORM_RELEASE_CONFIG_ID="${DATAFORM_RELEASE_CONFIG_ID:-production}"
  DATAFORM_GIT_COMMITISH="${DATAFORM_GIT_COMMITISH:-main}"
  DATAFORM_GIT_URL="${DATAFORM_GIT_URL:-}"
  DATAFORM_GIT_TOKEN_SECRET_VERSION="${DATAFORM_GIT_TOKEN_SECRET_VERSION:-}"

  if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    log_error "Set PROJECT_ID or run 'gcloud config set project <PROJECT_ID>'."
    exit 1
  fi

  validate_regex "PROJECT_ID" "${PROJECT_ID}" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' "a valid GCP project ID"
  validate_regex "REGION" "${REGION}" '^[a-z]+-[a-z0-9]+[0-9]$' "a GCP region (e.g. us-central1)"
  validate_regex "DATAFORM_LOCATION" "${DATAFORM_LOCATION}" '^[a-z]+-[a-z0-9]+[0-9]$' "a GCP region (e.g. us-central1)"
  validate_regex "BQ_LOCATION" "${BQ_LOCATION}" '^[A-Za-z0-9-]+$' "a BigQuery location (e.g. US)"
  validate_regex "FUNCTION_NAME" "${FUNCTION_NAME}" '^[a-z][a-z0-9-]{0,61}[a-z0-9]$' "a valid Cloud Run service name"
  validate_regex "BQ_DATASET" "${BQ_DATASET}" '^[A-Za-z0-9_]+$' "a BigQuery dataset identifier"
  validate_regex "BQ_ASSERTION_DATASET" "${BQ_ASSERTION_DATASET}" '^[A-Za-z0-9_]+$' "a BigQuery dataset identifier"
  validate_regex "BQ_CONNECTION_ID" "${BQ_CONNECTION_ID}" '^[A-Za-z0-9_-]+$' "a BigQuery connection ID"
  validate_regex "MAX_BATCHING_ROWS" "${MAX_BATCHING_ROWS}" '^[1-9][0-9]{0,2}$' "an integer between 1 and 999"
  validate_regex "DATAFORM_REPO_ID" "${DATAFORM_REPO_ID}" '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$' "a Dataform repository ID"
  validate_regex "DATAFORM_WORKSPACE_ID" "${DATAFORM_WORKSPACE_ID}" '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$' "a Dataform workspace ID"
  validate_regex "DATAFORM_RELEASE_CONFIG_ID" "${DATAFORM_RELEASE_CONFIG_ID}" '^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$' "a Dataform release config ID"
  validate_regex "DATAFORM_GIT_COMMITISH" "${DATAFORM_GIT_COMMITISH}" '^[A-Za-z0-9._/-]+$' "a valid Git branch, tag, or commit SHA"

  if [[ -n "${CLOUD_RUN_URL}" ]]; then
    validate_regex "CLOUD_RUN_URL" "${CLOUD_RUN_URL}" '^https://[a-zA-Z0-9._-]+\.run\.app$' "a Cloud Run HTTPS URL"
  fi

  if [[ -n "${DATAFORM_GIT_URL}" ]]; then
    validate_regex "DATAFORM_GIT_URL" "${DATAFORM_GIT_URL}" '^https://[^[:space:]]+$' "an HTTPS Git repository URL"
  fi

  if [[ -n "${DATAFORM_GIT_TOKEN_SECRET_VERSION}" ]]; then
    if [[ -z "${DATAFORM_GIT_URL}" ]]; then
      log_error "DATAFORM_GIT_TOKEN_SECRET_VERSION requires DATAFORM_GIT_URL to be set."
      exit 1
    fi
    validate_regex \
      "DATAFORM_GIT_TOKEN_SECRET_VERSION" \
      "${DATAFORM_GIT_TOKEN_SECRET_VERSION}" \
      '^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/secrets/[A-Za-z0-9_-]{1,255}/versions/([0-9]+|latest)$' \
      "projects/<project>/secrets/<secret>/versions/<version>"
  fi

  DATAFORM_CORE_VERSION="$(awk '/^dataformCoreVersion:/ {print $2; exit}' "${WORKFLOW_SETTINGS_FILE}" | tr -d "\"'[:space:]")"
  if [[ -z "${DATAFORM_CORE_VERSION}" ]]; then
    DATAFORM_CORE_VERSION="3.0.62"
  fi
  validate_regex "DATAFORM_CORE_VERSION" "${DATAFORM_CORE_VERSION}" '^[0-9]+\.[0-9]+\.[0-9]+$' "a semantic version (e.g. 3.0.62)"

  REPO_PARENT="projects/${PROJECT_ID}/locations/${DATAFORM_LOCATION}"
  REPO_RESOURCE="${REPO_PARENT}/repositories/${DATAFORM_REPO_ID}"
  WORKSPACE_RESOURCE="${REPO_RESOURCE}/workspaces/${DATAFORM_WORKSPACE_ID}"
  RELEASE_CONFIG_RESOURCE="${REPO_RESOURCE}/releaseConfigs/${DATAFORM_RELEASE_CONFIG_ID}"

  if [[ "${QUIET_MODE}" == "true" ]]; then
    log_info "Starting Dataform setup in QUIET mode (no confirmation prompts; all modifications logged)."
  else
    log_info "Starting Dataform setup in VERBOSE interactive mode (confirmation required for every modification)."
  fi
  log_info "Target: project=${PROJECT_ID}, dataform_location=${DATAFORM_LOCATION}, repo=${DATAFORM_REPO_ID}, bq_location=${BQ_LOCATION}"
}

# ------------------------------------------------------------------------------
# Dataform REST API Helper
# ------------------------------------------------------------------------------
API_HTTP_STATUS=""
API_RESPONSE_BODY=""

dataform_api_request() {
  local method="$1"
  local url="$2"
  local payload="${3:-}"

  local access_token
  set +x
  access_token="$(gcloud auth print-access-token 2>/dev/null || true)"
  if [[ -z "${access_token}" ]]; then
    log_error "Failed to acquire gcloud access token. Run 'gcloud auth login' and try again."
    exit 1
  fi

  local tmp_body
  tmp_body="$(mktemp)"
  local http_status=""

  if [[ -n "${payload}" ]]; then
    http_status="$(curl -sS -o "${tmp_body}" -w '%{http_code}' \
      -X "${method}" \
      -H "Authorization: Bearer ${access_token}" \
      -H "Content-Type: application/json" \
      -H "X-Goog-User-Project: ${PROJECT_ID}" \
      --data-binary "${payload}" \
      "${url}")"
  else
    http_status="$(curl -sS -o "${tmp_body}" -w '%{http_code}' \
      -X "${method}" \
      -H "Authorization: Bearer ${access_token}" \
      -H "X-Goog-User-Project: ${PROJECT_ID}" \
      "${url}")"
  fi
  unset access_token

  API_HTTP_STATUS="${http_status}"
  API_RESPONSE_BODY="$(cat "${tmp_body}")"
  rm -f "${tmp_body}"
}

require_api_2xx() {
  local action_desc="$1"
  if [[ ! "${API_HTTP_STATUS}" =~ ^2[0-9][0-9]$ ]]; then
    log_error "${action_desc} failed (HTTP ${API_HTTP_STATUS})."
    printf '%s\n' "${API_RESPONSE_BODY}" >&2
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Step 1: Enable Dataform API
# ------------------------------------------------------------------------------
step_enable_dataform_api() {
  log_step 1 "Enable Google Cloud Dataform API"

  local enabled_apis
  enabled_apis="$(gcloud services list --enabled --project="${PROJECT_ID}" --format='value(config.name)' 2>/dev/null || true)"

  if ! printf '%s\n' "${enabled_apis}" | grep -Fqx -- "dataform.googleapis.com"; then
    confirm_modification \
      "Enable Dataform API in project '${PROJECT_ID}'" \
      "Project: ${PROJECT_ID}" \
      "Enable API: dataform.googleapis.com"

    gcloud services enable dataform.googleapis.com --project="${PROJECT_ID}"
    log_modified "Enabled dataform.googleapis.com in '${PROJECT_ID}'"
  else
    log_unchanged "dataform.googleapis.com is already enabled in '${PROJECT_ID}'."
  fi
}

# ------------------------------------------------------------------------------
# Step 2: Resolve Cloud Run endpoint URL
# ------------------------------------------------------------------------------
step_resolve_cloud_run_endpoint() {
  log_step 2 "Resolve Cloud Run endpoint URL (read-only)"

  if [[ -n "${CLOUD_RUN_URL}" ]]; then
    log_verified "Using provided CLOUD_RUN_URL: ${CLOUD_RUN_URL}"
    return 0
  fi

  CLOUD_RUN_URL="$(gcloud run services describe "${FUNCTION_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --format='value(status.url)' 2>/dev/null || true)"

  if [[ -z "${CLOUD_RUN_URL}" ]]; then
    log_error "Could not resolve Cloud Run URL for service '${FUNCTION_NAME}' in '${PROJECT_ID}/${REGION}'."
    printf '       Run ./deploy.sh first, or export CLOUD_RUN_URL="https://<service>.run.app".\n' >&2
    exit 1
  fi

  validate_regex "CLOUD_RUN_URL" "${CLOUD_RUN_URL}" '^https://[a-zA-Z0-9._-]+\.run\.app$' "a Cloud Run HTTPS URL"
  log_verified "Resolved Cloud Run endpoint for '${FUNCTION_NAME}': ${CLOUD_RUN_URL}"
}

# ------------------------------------------------------------------------------
# Step 3: Create or configure Dataform repository
# ------------------------------------------------------------------------------
build_repo_payload() {
  local base_json
  base_json="$(jq -n \
    --arg display_name "${DATAFORM_REPO_DISPLAY_NAME}" \
    --arg default_db "${PROJECT_ID}" \
    '{
      displayName: $display_name,
      setAuthenticatedUserAdmin: true,
      workspaceCompilationOverrides: {
        defaultDatabase: $default_db
      }
    }')"

  if [[ -n "${DATAFORM_GIT_URL}" ]]; then
    if [[ -n "${DATAFORM_GIT_TOKEN_SECRET_VERSION}" ]]; then
      base_json="$(printf '%s' "${base_json}" | jq \
        --arg url "${DATAFORM_GIT_URL}" \
        --arg branch "${DATAFORM_GIT_COMMITISH}" \
        --arg secret_ver "${DATAFORM_GIT_TOKEN_SECRET_VERSION}" \
        '. + {
          gitRemoteSettings: {
            url: $url,
            defaultBranch: $branch,
            authenticationTokenSecretVersion: $secret_ver
          }
        }')"
    else
      base_json="$(printf '%s' "${base_json}" | jq \
        --arg url "${DATAFORM_GIT_URL}" \
        --arg branch "${DATAFORM_GIT_COMMITISH}" \
        '. + {
          gitRemoteSettings: {
            url: $url,
            defaultBranch: $branch
          }
        }')"
    fi
  fi

  printf '%s' "${base_json}"
}

step_ensure_dataform_repository() {
  log_step 3 "Create or configure Dataform repository"

  dataform_api_request "GET" "${DATAFORM_API_BASE}/${REPO_RESOURCE}"

  if [[ "${API_HTTP_STATUS}" == "404" ]]; then
    local payload
    payload="$(build_repo_payload)"

    local details=(
      "Project: ${PROJECT_ID}"
      "Location: ${DATAFORM_LOCATION}"
      "Repository ID: ${DATAFORM_REPO_ID}"
      "Display name: ${DATAFORM_REPO_DISPLAY_NAME}"
      "workspaceCompilationOverrides.defaultDatabase: ${PROJECT_ID}"
      "setAuthenticatedUserAdmin: true"
    )
    if [[ -n "${DATAFORM_GIT_URL}" ]]; then
      details+=("Git remote URL: ${DATAFORM_GIT_URL} (branch: ${DATAFORM_GIT_COMMITISH})")
    else
      details+=("Repository mode: Dataform-hosted (native Git storage)")
    fi

    confirm_modification \
      "Create Dataform repository '${DATAFORM_REPO_ID}'" \
      "${details[@]}"

    dataform_api_request "POST" \
      "${DATAFORM_API_BASE}/${REPO_PARENT}/repositories?repositoryId=${DATAFORM_REPO_ID}" \
      "${payload}"
    require_api_2xx "Create Dataform repository '${DATAFORM_REPO_ID}'"
    log_modified "Created Dataform repository '${REPO_RESOURCE}'"
    return 0
  fi

  require_api_2xx "Inspect Dataform repository '${DATAFORM_REPO_ID}'"

  local current_default_db current_display_name current_git_url current_git_branch current_git_secret
  current_default_db="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.workspaceCompilationOverrides.defaultDatabase // ""')"
  current_display_name="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.displayName // ""')"
  current_git_url="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.gitRemoteSettings.url // ""')"
  current_git_branch="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.gitRemoteSettings.defaultBranch // ""')"
  current_git_secret="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.gitRemoteSettings.authenticationTokenSecretVersion // ""')"

  local needs_patch="false"
  local update_fields=()
  local patch_details=("Repository: ${REPO_RESOURCE}")

  if [[ "${current_default_db}" != "${PROJECT_ID}" ]]; then
    needs_patch="true"
    update_fields+=("workspaceCompilationOverrides")
    patch_details+=("workspaceCompilationOverrides.defaultDatabase: '${current_default_db}' -> '${PROJECT_ID}'")
  fi

  if [[ "${current_display_name}" != "${DATAFORM_REPO_DISPLAY_NAME}" ]]; then
    needs_patch="true"
    update_fields+=("displayName")
    patch_details+=("displayName: '${current_display_name}' -> '${DATAFORM_REPO_DISPLAY_NAME}'")
  fi

  if [[ -n "${DATAFORM_GIT_URL}" ]]; then
    if [[ "${current_git_url}" != "${DATAFORM_GIT_URL}" \
       || "${current_git_branch}" != "${DATAFORM_GIT_COMMITISH}" \
       || "${current_git_secret}" != "${DATAFORM_GIT_TOKEN_SECRET_VERSION}" ]]; then
      needs_patch="true"
      update_fields+=("gitRemoteSettings")
      patch_details+=("gitRemoteSettings.url: '${current_git_url}' -> '${DATAFORM_GIT_URL}' (branch: ${DATAFORM_GIT_COMMITISH})")
    fi
  fi

  if [[ "${needs_patch}" == "true" ]]; then
    local update_mask
    update_mask="$(IFS=,; printf '%s' "${update_fields[*]}")"
    local payload
    payload="$(build_repo_payload | jq 'del(.setAuthenticatedUserAdmin)')"

    confirm_modification \
      "Update Dataform repository '${DATAFORM_REPO_ID}' configuration" \
      "${patch_details[@]}"

    dataform_api_request "PATCH" \
      "${DATAFORM_API_BASE}/${REPO_RESOURCE}?updateMask=${update_mask}" \
      "${payload}"
    require_api_2xx "Update Dataform repository '${DATAFORM_REPO_ID}'"
    log_modified "Updated Dataform repository '${REPO_RESOURCE}' (${update_mask})"
  else
    log_unchanged "Dataform repository '${REPO_RESOURCE}' is already configured."
  fi
}

# ------------------------------------------------------------------------------
# Step 4: Grant BigQuery & Connection IAM roles to Dataform service agent
# ------------------------------------------------------------------------------
step_grant_dataform_iam() {
  log_step 4 "Grant BigQuery and Connection IAM roles to Dataform service agent"

  local project_number
  project_number="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
  DATAFORM_SERVICE_AGENT="service-${project_number}@gcp-sa-dataform.iam.gserviceaccount.com"
  log_info "Dataform service agent: ${DATAFORM_SERVICE_AGENT}"

  local required_roles=(
    roles/bigquery.jobUser
    roles/bigquery.dataEditor
    roles/bigquery.dataViewer
    roles/bigquery.connectionUser
  )

  local iam_json
  iam_json="$(gcloud projects get-iam-policy "${PROJECT_ID}" --format=json)"

  local missing_roles=()
  local role
  for role in "${required_roles[@]}"; do
    if ! printf '%s' "${iam_json}" | jq -e \
      --arg role "${role}" \
      --arg member "serviceAccount:${DATAFORM_SERVICE_AGENT}" \
      '[.bindings[]? | select(.role == $role) | .members[]?] | index($member) != null' >/dev/null; then
      missing_roles+=("${role}")
    fi
  done

  if [[ ${#missing_roles[@]} -gt 0 ]]; then
    local detail_lines=(
      "Project: ${PROJECT_ID}"
      "Member: serviceAccount:${DATAFORM_SERVICE_AGENT}"
    )
    for role in "${missing_roles[@]}"; do
      detail_lines+=("Grant role: ${role}")
    done

    confirm_modification \
      "Grant ${#missing_roles[@]} BigQuery IAM role(s) to Dataform service agent" \
      "${detail_lines[@]}"

    for role in "${missing_roles[@]}"; do
      gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:${DATAFORM_SERVICE_AGENT}" \
        --role="${role}" \
        --quiet >/dev/null
    done
    log_modified "Granted IAM roles on '${PROJECT_ID}' to '${DATAFORM_SERVICE_AGENT}': ${missing_roles[*]}"
  else
    log_unchanged "Dataform service agent '${DATAFORM_SERVICE_AGENT}' already has all required BigQuery IAM roles."
  fi

  if [[ -n "${DATAFORM_GIT_TOKEN_SECRET_VERSION}" ]]; then
    local secret_project secret_name
    secret_project="$(printf '%s' "${DATAFORM_GIT_TOKEN_SECRET_VERSION}" | awk -F'/' '{print $2}')"
    secret_name="$(printf '%s' "${DATAFORM_GIT_TOKEN_SECRET_VERSION}" | awk -F'/' '{print $4}')"

    local secret_iam_json
    secret_iam_json="$(gcloud secrets get-iam-policy "${secret_name}" --project="${secret_project}" --format=json)"

    if ! printf '%s' "${secret_iam_json}" | jq -e \
      --arg member "serviceAccount:${DATAFORM_SERVICE_AGENT}" \
      '[.bindings[]? | select(.role == "roles/secretmanager.secretAccessor") | .members[]?] | index($member) != null' >/dev/null; then
      confirm_modification \
        "Grant Dataform service agent access to Git auth secret '${secret_name}'" \
        "Secret project: ${secret_project}" \
        "Secret: ${secret_name}" \
        "Member: serviceAccount:${DATAFORM_SERVICE_AGENT}" \
        "Role: roles/secretmanager.secretAccessor"

      gcloud secrets add-iam-policy-binding "${secret_name}" \
        --project="${secret_project}" \
        --member="serviceAccount:${DATAFORM_SERVICE_AGENT}" \
        --role="roles/secretmanager.secretAccessor" \
        --quiet >/dev/null
      log_modified "Granted roles/secretmanager.secretAccessor on '${secret_project}/${secret_name}' to '${DATAFORM_SERVICE_AGENT}'"
    else
      log_unchanged "Dataform service agent already has roles/secretmanager.secretAccessor on '${secret_project}/${secret_name}'."
    fi
  fi
}

# ------------------------------------------------------------------------------
# Step 5: Commit rendered workflow_settings.yaml and definitions/ to native repo
# ------------------------------------------------------------------------------
render_workflow_settings() {
  cat <<EOF
defaultProject: ${PROJECT_ID}
defaultLocation: ${BQ_LOCATION}
defaultDataset: ${BQ_DATASET}
defaultAssertionDataset: ${BQ_ASSERTION_DATASET}
dataformCoreVersion: ${DATAFORM_CORE_VERSION}
vars:
  cloudRunEndpoint: "${CLOUD_RUN_URL}"
  bqConnectionId: "${BQ_CONNECTION_ID}"
  maxBatchingRows: "${MAX_BATCHING_ROWS}"
EOF
}

step_sync_repository_files() {
  log_step 5 "Configure workflow_settings.yaml and sync definitions/ to Dataform repository"

  if [[ -n "${DATAFORM_GIT_URL}" ]]; then
    log_info "External Git remote is configured (${DATAFORM_GIT_URL}); skipping direct Dataform file commit."
    log_info "defaultProject and cloudRunEndpoint will be applied via workspaceCompilationOverrides and the Release Config."
    return 0
  fi

  local active_account
  active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
  if [[ -z "${active_account}" ]]; then
    active_account="dataform-setup@${PROJECT_ID}.iam.gserviceaccount.com"
  fi
  local author_name="${active_account%%@*}"

  local rendered_yaml
  rendered_yaml="$(render_workflow_settings)"
  local rendered_yaml_b64
  rendered_yaml_b64="$(printf '%s\n' "${rendered_yaml}" | base64 | tr -d '\n')"

  local file_ops_json
  file_ops_json="$(jq -n --arg b64 "${rendered_yaml_b64}" '{
    "workflow_settings.yaml": {
      writeFile: {
        contents: $b64
      }
    }
  }')"

  local synced_files=("workflow_settings.yaml (rendered with defaultProject=${PROJECT_ID}, cloudRunEndpoint=${CLOUD_RUN_URL})")
  local abs_file rel_file file_b64
  while IFS= read -r abs_file; do
    [[ -z "${abs_file}" ]] && continue
    rel_file="${abs_file#"${SCRIPT_DIR}/"}"
    file_b64="$(base64 < "${abs_file}" | tr -d '\n')"
    file_ops_json="$(printf '%s' "${file_ops_json}" | jq \
      --arg path "${rel_file}" \
      --arg b64 "${file_b64}" \
      '. + {($path): {writeFile: {contents: $b64}}}')"
    synced_files+=("${rel_file}")
  done < <(find "${DEFINITIONS_DIR}" -type f | LC_ALL=C sort)

  local commit_payload
  commit_payload="$(jq -n \
    --arg name "${author_name}" \
    --arg email "${active_account}" \
    --arg msg "chore(dataform): configure workflow_settings.yaml and sync definitions" \
    --argjson ops "${file_ops_json}" \
    '{
      commitMetadata: {
        author: {
          name: $name,
          emailAddress: $email
        },
        commitMessage: $msg
      },
      fileOperations: $ops
    }')"

  local detail_lines=(
    "Repository: ${REPO_RESOURCE}"
    "Local workflow_settings.yaml: untouched (placeholders preserved for git security)"
    "Remote workflow_settings.yaml defaultProject: ${PROJECT_ID}"
    "Remote workflow_settings.yaml vars.cloudRunEndpoint: ${CLOUD_RUN_URL}"
    "Files to commit (${#synced_files[@]}):"
  )
  local item
  for item in "${synced_files[@]}"; do
    detail_lines+=("  ${item}")
  done

  confirm_modification \
    "Commit configured workflow_settings.yaml and definitions/ to Dataform repository '${DATAFORM_REPO_ID}'" \
    "${detail_lines[@]}"

  dataform_api_request "POST" "${DATAFORM_API_BASE}/${REPO_RESOURCE}:commit" "${commit_payload}"
  require_api_2xx "Commit files to Dataform repository '${DATAFORM_REPO_ID}'"
  log_modified "Committed workflow_settings.yaml (defaultProject=${PROJECT_ID}, cloudRunEndpoint=${CLOUD_RUN_URL}) and ${#synced_files[@]} total file(s) to '${REPO_RESOURCE}'"
}

# ------------------------------------------------------------------------------
# Step 6: Ensure Dataform development workspace exists
# ------------------------------------------------------------------------------
step_ensure_workspace() {
  log_step 6 "Ensure Dataform development workspace exists"

  dataform_api_request "GET" "${DATAFORM_API_BASE}/${WORKSPACE_RESOURCE}"

  if [[ "${API_HTTP_STATUS}" == "404" ]]; then
    confirm_modification \
      "Create Dataform workspace '${DATAFORM_WORKSPACE_ID}'" \
      "Repository: ${REPO_RESOURCE}" \
      "Workspace ID: ${DATAFORM_WORKSPACE_ID}"

    dataform_api_request "POST" \
      "${DATAFORM_API_BASE}/${REPO_RESOURCE}/workspaces?workspaceId=${DATAFORM_WORKSPACE_ID}" \
      "{}"
    require_api_2xx "Create Dataform workspace '${DATAFORM_WORKSPACE_ID}'"
    log_modified "Created Dataform workspace '${WORKSPACE_RESOURCE}'"
  else
    require_api_2xx "Inspect Dataform workspace '${DATAFORM_WORKSPACE_ID}'"
    log_unchanged "Dataform workspace '${WORKSPACE_RESOURCE}' already exists."
  fi
}

# ------------------------------------------------------------------------------
# Step 7: Create or update Dataform Release Config
# ------------------------------------------------------------------------------
build_release_config_payload() {
  jq -n \
    --arg commitish "${DATAFORM_GIT_COMMITISH}" \
    --arg default_db "${PROJECT_ID}" \
    --arg default_loc "${BQ_LOCATION}" \
    --arg default_schema "${BQ_DATASET}" \
    --arg assertion_schema "${BQ_ASSERTION_DATASET}" \
    --arg endpoint "${CLOUD_RUN_URL}" \
    --arg conn_id "${BQ_CONNECTION_ID}" \
    --arg max_batch "${MAX_BATCHING_ROWS}" \
    '{
      gitCommitish: $commitish,
      codeCompilationConfig: {
        defaultDatabase: $default_db,
        defaultLocation: $default_loc,
        defaultSchema: $default_schema,
        assertionSchema: $assertion_schema,
        vars: {
          cloudRunEndpoint: $endpoint,
          bqConnectionId: $conn_id,
          maxBatchingRows: $max_batch
        }
      }
    }'
}

step_ensure_release_config() {
  log_step 7 "Configure Dataform release config (defaultProject & cloudRunEndpoint)"

  local desired_payload
  desired_payload="$(build_release_config_payload)"

  dataform_api_request "GET" "${DATAFORM_API_BASE}/${RELEASE_CONFIG_RESOURCE}"

  if [[ "${API_HTTP_STATUS}" == "404" ]]; then
    confirm_modification \
      "Create Dataform release config '${DATAFORM_RELEASE_CONFIG_ID}'" \
      "Repository: ${REPO_RESOURCE}" \
      "Release config ID: ${DATAFORM_RELEASE_CONFIG_ID}" \
      "gitCommitish: ${DATAFORM_GIT_COMMITISH}" \
      "codeCompilationConfig.defaultDatabase: ${PROJECT_ID}" \
      "codeCompilationConfig.defaultLocation: ${BQ_LOCATION}" \
      "codeCompilationConfig.defaultSchema: ${BQ_DATASET}" \
      "codeCompilationConfig.assertionSchema: ${BQ_ASSERTION_DATASET}" \
      "codeCompilationConfig.vars.cloudRunEndpoint: ${CLOUD_RUN_URL}" \
      "codeCompilationConfig.vars.bqConnectionId: ${BQ_CONNECTION_ID}" \
      "codeCompilationConfig.vars.maxBatchingRows: ${MAX_BATCHING_ROWS}"

    dataform_api_request "POST" \
      "${DATAFORM_API_BASE}/${REPO_RESOURCE}/releaseConfigs?releaseConfigId=${DATAFORM_RELEASE_CONFIG_ID}" \
      "${desired_payload}"
    require_api_2xx "Create Dataform release config '${DATAFORM_RELEASE_CONFIG_ID}'"
    log_modified "Created Dataform release config '${RELEASE_CONFIG_RESOURCE}'"
    return 0
  fi

  require_api_2xx "Inspect Dataform release config '${DATAFORM_RELEASE_CONFIG_ID}'"

  local current_normalized desired_normalized
  current_normalized="$(printf '%s' "${API_RESPONSE_BODY}" | jq -S '{
    gitCommitish: (.gitCommitish // ""),
    codeCompilationConfig: {
      defaultDatabase: (.codeCompilationConfig.defaultDatabase // ""),
      defaultLocation: (.codeCompilationConfig.defaultLocation // ""),
      defaultSchema: (.codeCompilationConfig.defaultSchema // ""),
      assertionSchema: (.codeCompilationConfig.assertionSchema // ""),
      vars: (.codeCompilationConfig.vars // {})
    }
  }')"
  desired_normalized="$(printf '%s' "${desired_payload}" | jq -S '.')"

  if [[ "${current_normalized}" != "${desired_normalized}" ]]; then
    confirm_modification \
      "Update Dataform release config '${DATAFORM_RELEASE_CONFIG_ID}'" \
      "Release config: ${RELEASE_CONFIG_RESOURCE}" \
      "gitCommitish: ${DATAFORM_GIT_COMMITISH}" \
      "codeCompilationConfig.defaultDatabase: ${PROJECT_ID}" \
      "codeCompilationConfig.defaultLocation: ${BQ_LOCATION}" \
      "codeCompilationConfig.defaultSchema: ${BQ_DATASET}" \
      "codeCompilationConfig.assertionSchema: ${BQ_ASSERTION_DATASET}" \
      "codeCompilationConfig.vars.cloudRunEndpoint: ${CLOUD_RUN_URL}"

    dataform_api_request "PATCH" \
      "${DATAFORM_API_BASE}/${RELEASE_CONFIG_RESOURCE}?updateMask=gitCommitish,codeCompilationConfig" \
      "${desired_payload}"
    require_api_2xx "Update Dataform release config '${DATAFORM_RELEASE_CONFIG_ID}'"
    log_modified "Updated Dataform release config '${RELEASE_CONFIG_RESOURCE}'"
  else
    log_unchanged "Dataform release config '${RELEASE_CONFIG_RESOURCE}' is already up to date."
  fi
}

# ------------------------------------------------------------------------------
# Step 8: Compile release config to verify configuration
# ------------------------------------------------------------------------------
step_verify_compilation() {
  log_step 8 "Compile Dataform release config to verify setup"

  local compile_payload
  compile_payload="$(jq -n --arg rc "${RELEASE_CONFIG_RESOURCE}" '{releaseConfig: $rc}')"

  confirm_modification \
    "Create Dataform compilation result for '${DATAFORM_RELEASE_CONFIG_ID}'" \
    "Repository: ${REPO_RESOURCE}" \
    "Release config: ${RELEASE_CONFIG_RESOURCE}" \
    "Effect: Compiles workflow_settings.yaml and definitions/ in Google Cloud Dataform to verify configuration"

  dataform_api_request "POST" \
    "${DATAFORM_API_BASE}/${REPO_RESOURCE}/compilationResults" \
    "${compile_payload}"
  require_api_2xx "Compile Dataform release config '${DATAFORM_RELEASE_CONFIG_ID}'"

  local error_count
  error_count="$(printf '%s' "${API_RESPONSE_BODY}" | jq '(.compilationErrors // []) | length')"
  if [[ "${error_count}" -gt 0 ]]; then
    log_error "Dataform compilation reported ${error_count} error(s):"
    printf '%s' "${API_RESPONSE_BODY}" | jq -r '.compilationErrors[] | "  - \(.path // "<unknown>"): \(.message // "unknown error")"' >&2
    exit 1
  fi

  COMPILATION_RESULT_NAME="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.name // ""')"
  local compiled_db compiled_endpoint
  compiled_db="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.codeCompilationConfig.defaultDatabase // ""')"
  compiled_endpoint="$(printf '%s' "${API_RESPONSE_BODY}" | jq -r '.codeCompilationConfig.vars.cloudRunEndpoint // ""')"

  log_modified "Created verified Dataform compilation result '${COMPILATION_RESULT_NAME}'"
  log_verified "Dataform compilation succeeded with 0 errors (defaultProject=${compiled_db}, cloudRunEndpoint=${compiled_endpoint})."
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
print_summary() {
  local console_url="https://console.cloud.google.com/bigquery/dataform/locations/${DATAFORM_LOCATION}/repositories/${DATAFORM_REPO_ID}?project=${PROJECT_ID}"

  printf '\n==============================================================================\n'
  printf 'Dataform Setup Complete\n'
  printf '==============================================================================\n'
  printf 'Repository       : %s\n' "${REPO_RESOURCE}"
  printf 'Workspace        : %s\n' "${WORKSPACE_RESOURCE}"
  printf 'Release Config   : %s\n' "${RELEASE_CONFIG_RESOURCE}"
  printf 'defaultProject   : %s\n' "${PROJECT_ID}"
  printf 'cloudRunEndpoint : %s\n' "${CLOUD_RUN_URL}"
  printf 'Dataform Console : %s\n' "${console_url}"

  printf '\nModifications applied (%d):\n' "${#MODIFICATIONS_LOG[@]}"
  if [[ ${#MODIFICATIONS_LOG[@]} -eq 0 ]]; then
    printf '  (none — all resources were already up to date)\n'
  else
    local item
    for item in "${MODIFICATIONS_LOG[@]}"; do
      printf '  * %s\n' "${item}"
    done
  fi
}

main() {
  parse_args "$@"
  check_prerequisites
  load_and_validate_config

  step_enable_dataform_api
  step_resolve_cloud_run_endpoint
  step_ensure_dataform_repository
  step_grant_dataform_iam
  step_sync_repository_files
  step_ensure_workspace
  step_ensure_release_config
  step_verify_compilation

  print_summary
}

main "$@"
