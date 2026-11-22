#!/usr/bin/env bash
# google-decision-api-demo — create a Google Cloud project and put billing on it.
#
# Run this FIRST, before ./deploy.sh. It leaves you with:
#   • a project that exists, is billing-linked, and is old enough to serve
#   • that project ID in ~/project_id.txt
#   • that project set as gcloud's active project
#
# Safe to re-run. A second run reuses the project recorded in
# ~/project_id.txt instead of creating another one.
#
# Modes:
#   Default (verbose/interactive): explains every modification before applying
#                                  it and asks for confirmation.
#   --quiet, -q:                   applies all modifications without prompting,
#                                  while logging every modification performed.
#   --help, -h:                    show usage information.
set -euo pipefail
umask 077

PROJECT_FILE="${PROJECT_FILE:-$HOME/project_id.txt}"
PREFIX="decision-api-demo-"
PROJECT_DISPLAY_NAME="Google Decision API Demo"
CREATE_ATTEMPTS=3      # fresh random ID per attempt; IDs are globally unique
READY_TIMEOUT=120      # seconds to wait for a new project to be serveable
READY_INTERVAL=10      # seconds between readiness probes

QUIET=0
ACTIVE_ACCOUNT=""
ACCOUNT_ID=""
ACCOUNT_DISPLAY=""
PROJECT_ID=""
MODIFIED_ITEMS=()

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
tick() { printf '  ✓ %s\n' "$1"; }
info() { printf '  · %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1" >&2; }

log_change() {
    local message="$1"
    MODIFIED_ITEMS+=("$message")
    printf '  ✓ [modified] %s\n' "$message"
}

die() {
    printf '\n\033[1m✗ %s\033[0m\n\n' "$1" >&2
    shift
    for line in "$@"; do printf '%s\n' "$line" >&2; done
    printf '\n' >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--quiet | -q] [--help | -h]

Provision (or reuse) a Google Cloud project with billing linked for
google-decision-api-demo.

Options:
  -q, --quiet   Non-interactive mode: apply all modifications without prompting
                for confirmation, while still logging every modification made.
  -h, --help    Show this help message and exit.

By default, the script runs in verbose interactive mode, explaining each
modification before applying it and asking for confirmation.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -q|--quiet)
                QUIET=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1" \
                    "Run '$(basename "$0") --help' for usage."
                ;;
        esac
        shift
    done
}

# Print a summary of all modifications applied during this run.
print_modifications_summary() {
    say "Modifications summary"
    if [ "${#MODIFIED_ITEMS[@]}" -eq 0 ]; then
        info "No modifications were made."
        return 0
    fi
    local item
    for item in "${MODIFIED_ITEMS[@]}"; do
        tick "$item"
    done
}

# Explain a planned modification and ask for confirmation unless --quiet is set.
# Usage: confirm_modification "<title>" "<detail line 1>" ["<detail line 2>" ...]
confirm_modification() {
    local title="$1"
    shift

    if [ "$QUIET" -eq 1 ]; then
        info "Auto-confirming (--quiet): $title"
        return 0
    fi

    printf '\n  \033[1mPlanned modification:\033[0m %s\n' "$title"
    local detail
    for detail in "$@"; do
        printf '    • %s\n' "$detail"
    done

    local reply=""
    printf '  Confirm this modification? [y/N]: '
    if ! IFS= read -r reply; then
        printf '\n'
        warn "No interactive input available (EOF)."
        if [ "${#MODIFIED_ITEMS[@]}" -gt 0 ]; then
            print_modifications_summary
        fi
        die "Aborted before: $title" \
            "Re-run interactively to confirm each step, or pass --quiet to run without prompts:" \
            "  ./project.sh --quiet"
    fi

    case "$reply" in
        [yY]|[yY][eE][sS])
            info "Confirmed by user."
            return 0
            ;;
        *)
            warn "Modification declined by user: $title"
            if [ "${#MODIFIED_ITEMS[@]}" -gt 0 ]; then
                print_modifications_summary
            fi
            die "Aborted by user." \
                "Re-run ./project.sh when you are ready to continue."
            ;;
    esac
}

# ── 0 · preflight checks ─────────────────────────────────────────────────────
check_prerequisites() {
    say "0 · Preflight checks"

    command -v gcloud >/dev/null 2>&1 || die \
        "gcloud not found." \
        "This script is written for Cloud Shell, where gcloud is preinstalled." \
        "On a laptop, install the Google Cloud SDK first:" \
        "  https://cloud.google.com/sdk/docs/install"
    tick "gcloud CLI found"

    ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
    if [ -z "$ACTIVE_ACCOUNT" ]; then
        die "No active gcloud account." \
            "Authenticate, then re-run this script:" \
            "  gcloud auth login"
    fi
    tick "active gcloud account: $ACTIVE_ACCOUNT"
}

# ── 1 · reuse the project from a previous run ────────────────────────────────
project_is_usable() {
    local pid="$1"
    gcloud projects describe "$pid" --format='value(projectId)' >/dev/null 2>&1 || return 1
    [ "$(gcloud billing projects describe "$pid" \
            --format='value(billingEnabled)' 2>/dev/null)" = "True" ] || return 1
    return 0
}

set_active_gcloud_project() {
    local target_project="$1"
    local current_project
    current_project="$(gcloud config get-value project 2>/dev/null || true)"
    if [ -z "$current_project" ]; then
        current_project="(unset)"
    fi

    if [ "$current_project" = "$target_project" ]; then
        info "gcloud active project is already set to $target_project (no change needed)"
        return 0
    fi

    confirm_modification "Set active gcloud project" \
        "Target config: gcloud core/project" \
        "Change:        $current_project → $target_project" \
        "Command:       gcloud config set project $target_project"

    gcloud config set project "$target_project" >/dev/null 2>&1
    log_change "Set active gcloud project: $current_project → $target_project"
}

try_reuse_existing_project() {
    if [ ! -f "$PROJECT_FILE" ]; then
        return 1
    fi

    local existing
    existing="$(tr -d '[:space:]' < "$PROJECT_FILE" || true)"
    if [ -z "$existing" ]; then
        return 1
    fi

    say "1 · Checking existing project"
    info "Found $PROJECT_FILE → $existing"

    if project_is_usable "$existing"; then
        tick "reusing $existing (exists, billing linked)"
        set_active_gcloud_project "$existing"
        print_modifications_summary
        say "Project ready: $existing"
        printf '  Next:  ./deploy.sh\n\n'
        return 0
    fi

    warn "$existing is missing or has no billing — creating a fresh project."
    return 1
}

# ── 2 · pick a billing account ───────────────────────────────────────────────
# One listing, filtered in bash. Preference order:
#   1. newest "[YYYY-MM-DD] GDP Credit: ..." account, if you have one
#   2. any open billing account (a personal card is perfectly fine)
# ISO dates sort correctly as plain strings, so `sort -r` picks the newest
# without any date parsing.
select_billing_account() {
    say "1 · Billing account"

    local billing_list
    billing_list="$(gcloud billing accounts list \
        --filter="open=true" \
        --format="value(displayName,name)" 2>/dev/null || true)"

    if [ -z "$billing_list" ]; then
        die "No open billing account on this Google account." \
            "This demo provisions Cloud Run, VPC/Cloud NAT, BigQuery, and Gemini" \
            "API resources, which need billing enabled." \
            "" \
            "If you were given a Google Cloud credit for this session, claim it" \
            "first — it takes about a minute and creates the billing account for" \
            "you. Then re-run:" \
            "" \
            "  ./project.sh" \
            "" \
            "No credit? Any Google Cloud account with billing works, including" \
            "the free trial:" \
            "  https://console.cloud.google.com/freetrial" \
            "" \
            "Already claimed one? Check that gcloud is signed in as the same" \
            "account you claimed it with:" \
            "  gcloud auth list"
    fi

    local gdp_line account_line account_name
    gdp_line="$(printf '%s\n' "$billing_list" \
        | grep -iE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}\][[:space:]]*GDP[[:space:]]+Credit:' \
        | sort -r | head -n 1 || true)"

    if [ -n "$gdp_line" ]; then
        account_line="$gdp_line"
        info "using the newest GDP Credit account"
    else
        account_line="$(printf '%s\n' "$billing_list" | head -n 1)"
        info "no GDP Credit account found — using your open billing account"
    fi

    # `value(a,b)` joins fields with a tab; take the last field as the resource
    # name, and strip the billingAccounts/ prefix if gcloud included it.
    account_name="${account_line##*$'\t'}"
    ACCOUNT_ID="${account_name#billingAccounts/}"
    ACCOUNT_DISPLAY="${account_line%%$'\t'*}"

    if [ -z "$ACCOUNT_ID" ]; then
        die "Could not read a billing account ID out of gcloud's output." \
            "Run this and link the project by hand:" \
            "  gcloud billing accounts list"
    fi

    tick "selected billing account: $ACCOUNT_DISPLAY ($ACCOUNT_ID)"
}

# ── 3 · create the project ───────────────────────────────────────────────────
# decision-api-demo-XXXX. Project IDs are unique across all of Google Cloud and
# a deleted ID stays reserved, so a collision is a normal outcome, not an error:
# retry with a new number before giving up.
create_project() {
    say "2 · Create Google Cloud project"

    local first_candidate
    first_candidate="${PREFIX}$(printf '%04d' $((RANDOM % 10000)))"

    confirm_modification "Create a new Google Cloud project" \
        "Account:      $ACTIVE_ACCOUNT" \
        "Project ID:   $first_candidate (random suffix; retries up to $CREATE_ATTEMPTS attempts if taken)" \
        "Display name: $PROJECT_DISPLAY_NAME" \
        "Command:      gcloud projects create <project-id> --name=\"$PROJECT_DISPLAY_NAME\""

    PROJECT_ID=""
    local create_err=""
    local attempt candidate
    for attempt in $(seq 1 "$CREATE_ATTEMPTS"); do
        if [ "$attempt" -eq 1 ]; then
            candidate="$first_candidate"
        else
            candidate="${PREFIX}$(printf '%04d' $((RANDOM % 10000)))"
        fi

        info "creating $candidate (attempt $attempt/$CREATE_ATTEMPTS)"
        if create_err="$(gcloud projects create "$candidate" \
                --name="$PROJECT_DISPLAY_NAME" 2>&1)"; then
            PROJECT_ID="$candidate"
            break
        fi
        warn "$candidate was refused, trying another ID"
    done

    if [ -z "$PROJECT_ID" ]; then
        die "Could not create a project." \
            "gcloud said:" \
            "" \
            "$create_err" \
            "" \
            "Usual causes: you are at your project quota, or your account is in" \
            "an organization that does not let you create projects." \
            "" \
            "Create one by hand instead — it takes a minute:" \
            "  1. https://console.cloud.google.com/projectcreate" \
            "  2. give it any name, note the PROJECT ID it assigns" \
            "  3. link billing:  Billing → Link a billing account" \
            "  4. tell this demo about it:" \
            "       echo YOUR_PROJECT_ID > ~/project_id.txt" \
            "       gcloud config set project YOUR_PROJECT_ID" \
            "  5. re-run ./project.sh — it will pick that project up"
    fi

    log_change "Created GCP project: $PROJECT_ID (name: \"$PROJECT_DISPLAY_NAME\")"
}

# ── 4 · link billing account ─────────────────────────────────────────────────
link_billing_account() {
    say "3 · Link billing account"

    confirm_modification "Link billing account to $PROJECT_ID" \
        "Project ID:      $PROJECT_ID" \
        "Billing account: $ACCOUNT_DISPLAY ($ACCOUNT_ID)" \
        "Effect:          Enables billable GCP services on $PROJECT_ID" \
        "Command:         gcloud billing projects link $PROJECT_ID --billing-account=$ACCOUNT_ID"

    local link_err=""
    if ! link_err="$(gcloud billing projects link "$PROJECT_ID" \
            --billing-account="$ACCOUNT_ID" 2>&1)"; then
        die "Created $PROJECT_ID but could not link billing to it." \
            "gcloud said:" \
            "" \
            "$link_err" \
            "" \
            "Link it in the console, then re-run this script (it will reuse the" \
            "project, not make another one):" \
            "  https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
    fi

    log_change "Linked billing account $ACCOUNT_DISPLAY ($ACCOUNT_ID) to project $PROJECT_ID"
}

# ── 5 · record project ID locally & set active gcloud project ────────────────
save_project_file() {
    say "4 · Save local project configuration"

    local previous_value="(file does not exist)"
    local action_label="Create $PROJECT_FILE"
    if [ -f "$PROJECT_FILE" ]; then
        previous_value="$(tr -d '[:space:]' < "$PROJECT_FILE" || true)"
        if [ -z "$previous_value" ]; then
            previous_value="(empty file)"
        fi
        action_label="Update $PROJECT_FILE"
    fi

    confirm_modification "$action_label" \
        "File:   $PROJECT_FILE" \
        "Change: $previous_value → $PROJECT_ID" \
        "Effect: Allows future runs of ./project.sh to reuse $PROJECT_ID"

    # Write this before the readiness wait: if the wait times out, a re-run has
    # to find this project rather than create a third one.
    printf '%s\n' "$PROJECT_ID" > "$PROJECT_FILE"
    log_change "Wrote project ID to $PROJECT_FILE ($previous_value → $PROJECT_ID)"

    set_active_gcloud_project "$PROJECT_ID"
}

# ── 6 · wait for the project to actually be allowed to serve ─────────────────
# A project that is seconds old will answer 403 IAM_PERMISSION_DENIED while its
# IAM policy propagates. ./deploy.sh enables APIs and provisions IAM/VPC/Cloud Run
# resources immediately, so absorb that wait here instead of failing there.
wait_for_project_ready() {
    say "5 · Waiting for the project to come up"
    info "a brand new project answers 403 for a minute or so — this is normal"

    local deadline ready
    deadline=$(( SECONDS + READY_TIMEOUT ))
    ready=0
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$(gcloud billing projects describe "$PROJECT_ID" \
                    --format='value(billingEnabled)' 2>/dev/null)" = "True" ] \
           && gcloud services list --enabled --project="$PROJECT_ID" \
                    --limit=1 --format='value(config.name)' >/dev/null 2>&1; then
            ready=1
            break
        fi
        printf '  · not ready yet, retrying in %ss\n' "$READY_INTERVAL"
        sleep "$READY_INTERVAL"
    done

    if [ "$ready" -ne 1 ]; then
        die "$PROJECT_ID is created and billing-linked, but still not serving after ${READY_TIMEOUT}s." \
            "Nothing is broken — new projects sometimes take longer than this to" \
            "propagate. Wait a minute, then run:" \
            "" \
            "  ./project.sh" \
            "" \
            "It will reuse $PROJECT_ID rather than create another project."
    fi

    tick "$PROJECT_ID is serving"
}

main() {
    parse_args "$@"

    say "Google Decision API Demo · project + billing"
    if [ "$QUIET" -eq 1 ]; then
        info "Mode: quiet (applying modifications without prompts; logging all changes)"
    else
        info "Mode: verbose interactive (explaining each modification and asking for confirmation)"
    fi

    check_prerequisites

    if try_reuse_existing_project; then
        exit 0
    fi

    select_billing_account
    create_project
    link_billing_account
    save_project_file
    wait_for_project_ready

    print_modifications_summary
    say "Project ready: $PROJECT_ID"
    printf '  Next:  ./deploy.sh\n\n'
}

main "$@"
