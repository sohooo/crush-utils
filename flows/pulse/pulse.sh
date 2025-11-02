#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE >&2
Usage: $0 <gitlab-group-path-or-id> [output-file]

Environment variables:
  GITLAB_BASE_URL   Base URL of the GitLab instance (default: https://gitlab.com)
  GITLAB_TOKEN      Personal access token with API scope (if not authenticated via glab)
  PULSE_DAYS        Number of days to include in the snapshot (default: 7)
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

if ! command -v glab >/dev/null 2>&1; then
  echo "Error: glab CLI is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

GROUP_INPUT="$1"
OUTPUT_PATH="${2:-}"

BASE_URL="${GITLAB_BASE_URL:-https://gitlab.com}"
DAYS="${PULSE_DAYS:-7}"

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: PULSE_DAYS must be an integer (received '$DAYS')." >&2
  exit 1
fi

NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if ! SINCE_DATE="$(date -u -d "${DAYS} days ago" +"%Y-%m-%d" 2>/dev/null)"; then
  echo "Error: GNU date is required (missing \"-d\" support)." >&2
  exit 1
fi

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

GROUP_ENCODED="$(urlencode "$GROUP_INPUT")"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GROUP_JSON_PATH="$TMP_DIR/group.json"
ISSUES_JSON_PATH="$TMP_DIR/issues.json"
MRS_JSON_PATH="$TMP_DIR/mrs.json"
COMMITS_JSON_PATH="$TMP_DIR/commits.json"

GLAB_HOSTNAME="${BASE_URL#*://}"
GLAB_HOSTNAME="${GLAB_HOSTNAME%%/}"

GLAB_ARGS=(api)
if [[ -n "$GLAB_HOSTNAME" ]]; then
  GLAB_ARGS+=(--hostname "$GLAB_HOSTNAME")
fi

glab_api() {
  glab "${GLAB_ARGS[@]}" "$@"
}

if ! glab auth status >/dev/null 2>&1; then
  if [[ -z "${GITLAB_TOKEN:-}" ]]; then
    echo "Error: glab is not authenticated. Run 'glab auth login' or set GITLAB_TOKEN." >&2
    exit 1
  fi
fi

glab_api "/groups/$GROUP_ENCODED" >"$GROUP_JSON_PATH"
GROUP_ID="$(jq -r '.id' "$GROUP_JSON_PATH")"

if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
  echo "Error: unable to resolve group '$GROUP_INPUT'." >&2
  exit 1
fi

glab_api \
  --field "created_after=$SINCE_DATE" \
  --field "per_page=100" \
  --field "order_by=created_at" \
  --field "sort=desc" \
  "/groups/$GROUP_ID/issues" >"$ISSUES_JSON_PATH"

glab_api \
  --field "state=merged" \
  --field "updated_after=$SINCE_DATE" \
  --field "per_page=100" \
  --field "order_by=updated_at" \
  --field "sort=desc" \
  "/groups/$GROUP_ID/merge_requests" >"$MRS_JSON_PATH"

glab_api \
  --field "action=pushed" \
  --field "after=$SINCE_DATE" \
  --field "per_page=100" \
  --field "sort=desc" \
  "/groups/$GROUP_ID/events" >"$COMMITS_JSON_PATH"

if [[ -z "$OUTPUT_PATH" ]]; then
  SAFE_GROUP="${GROUP_INPUT//\//-}"
  OUTPUT_PATH="pulse-${SAFE_GROUP}-$(date +%Y-%m-%d).json"
fi

jq -n \
  --slurpfile group "$GROUP_JSON_PATH" \
  --slurpfile issues "$ISSUES_JSON_PATH" \
  --slurpfile merge_requests "$MRS_JSON_PATH" \
  --slurpfile commits "$COMMITS_JSON_PATH" \
  --arg since "$SINCE_DATE" \
  --arg until "$NOW_UTC" \
  '{
    group: {
      id: ($group[0].id),
      full_path: ($group[0].full_path),
      web_url: ($group[0].web_url),
      description: ($group[0].description)
    },
    timeframe: { since: $since, until: $until },
    stats: {
      issues: ($issues[0] | length),
      merge_requests: ($merge_requests[0] | length),
      commits: ($commits[0] | length)
    },
    issues: $issues[0],
    merge_requests: $merge_requests[0],
    commits: $commits[0]
  }' >"$OUTPUT_PATH"

echo "Saved pulse data to $OUTPUT_PATH"
