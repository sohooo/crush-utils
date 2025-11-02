#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE >&2
Usage: $0 <gitlab-username> [days]

Environment variables:
  GITLAB_BASE_URL   Base URL of the GitLab instance (default: https://gitlab.com)
  GITLAB_TOKEN      Personal access token with API scope
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../common.sh
source "$SCRIPT_DIR/../common.sh"

USERNAME="$1"
DAYS="${2:-7}"

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: days must be an integer (received '$DAYS')." >&2
  exit 1
fi

load_repo_env "$REPO_DIR"

require_commands crush curl jq

BASE_URL="${GITLAB_BASE_URL:-https://gitlab.com}"

init_gitlab_api "$BASE_URL"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

USER_JSON_PATH="$TMP_DIR/user.json"
EVENTS_JSON_PATH="$TMP_DIR/events_raw.json"
OVERVIEW_PATH="$TMP_DIR/context_overview.txt"

if ! gitlab_api_get \
  "/users" \
  "username=$(urlencode "$USERNAME")" >"$USER_JSON_PATH"; then
  echo "Error: failed to resolve GitLab user '$USERNAME'." >&2
  exit 1
fi

USER_ID="$(jq -r '.[0].id // empty' "$USER_JSON_PATH")"

if [[ -z "$USER_ID" ]]; then
  echo "Error: unable to find GitLab user '$USERNAME'." >&2
  exit 1
fi

NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
if ! SINCE_UTC="$(date -u -d "${DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)"; then
  echo "Error: GNU date is required (missing \"-d\" support)." >&2
  exit 1
fi

if ! gitlab_api_get \
  "/users/$USER_ID/events" \
  "after=$(urlencode "$SINCE_UTC")" \
  "per_page=100" \
  "sort=desc" >"$EVENTS_JSON_PATH"; then
  echo "Error: failed to fetch activity for user '$USERNAME'." >&2
  exit 1
fi

USER_NAME="$(jq -r '.[0].name // .[0].username' "$USER_JSON_PATH")"

cat <<CONTEXT >"$OVERVIEW_PATH"
GitLab user activity capture
============================

User: $USER_NAME (@$USERNAME)
Timeframe: last $DAYS day(s) ($SINCE_UTC to $NOW_UTC)

Files included in this context directory:
- user.json: Raw response for the user lookup
- events_raw.json: Raw events returned by the GitLab API

Use these artefacts to produce a concise summary of the user's recent GitLab activity, highlight notable contributions, and flag any follow-ups. Refer directly to the raw events for details.
CONTEXT

PROMPT="You are an engineering lead reviewing recent GitLab activity for @$USERNAME over the past $DAYS day(s). Use the provided raw GitLab events to describe key contributions, themes, and recommended follow-ups. Be specific about repositories, merge requests, and issues where possible."

export CRUSH_USER_ACTIVITY_USERNAME="$USERNAME"
export CRUSH_USER_ACTIVITY_DAYS="$DAYS"

env \
  CRUSH_CONTEXT_PATH="$TMP_DIR" \
  CRUSH_INITIAL_PROMPT="$PROMPT" \
  crush run flows/user_activity
