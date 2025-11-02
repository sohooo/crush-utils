#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE >&2
Aufruf: $0 <gitlab-gruppenpfad-oder-id> [ausgabedatei]

Umgebungsvariablen:
  GITLAB_BASE_URL   Basis-URL der GitLab-Instanz (Standard: https://gitlab.com)
  GITLAB_TOKEN      Personal Access Token mit API-Rechten
  PULSE_DAYS        Anzahl der Tage, die im Snapshot enthalten sein sollen (Standard: 7)
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

GROUP_INPUT="$1"
OUTPUT_PATH="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../common.sh
source "$SCRIPT_DIR/../common.sh"

load_repo_env "$REPO_DIR"

require_commands curl jq

BASE_URL="${GITLAB_BASE_URL:-https://gitlab.com}"
DAYS="${PULSE_DAYS:-7}"

init_gitlab_api "$BASE_URL"

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Fehler: PULSE_DAYS muss eine Ganzzahl sein (erhalten: '$DAYS')." >&2
  exit 1
fi

NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if ! SINCE_DATE="$(date -u -d "${DAYS} days ago" +"%Y-%m-%d" 2>/dev/null)"; then
  echo "Fehler: GNU date wird benötigt (Unterstützung für \"-d\" fehlt)." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GROUP_JSON_PATH="$TMP_DIR/group.json"
ISSUES_JSON_PATH="$TMP_DIR/issues.json"
MRS_JSON_PATH="$TMP_DIR/mrs.json"
COMMITS_JSON_PATH="$TMP_DIR/commits.json"

GROUP_ENCODED="$(urlencode "$GROUP_INPUT")"

if ! gitlab_api_get "/groups/$GROUP_ENCODED" >"$GROUP_JSON_PATH"; then
  echo "Fehler: Die Gruppe '$GROUP_INPUT' konnte nicht ermittelt werden." >&2
  exit 1
fi

GROUP_ID="$(jq -r '.id' "$GROUP_JSON_PATH")"

if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
  echo "Fehler: Die Gruppe '$GROUP_INPUT' konnte nicht ermittelt werden." >&2
  exit 1
fi

if ! gitlab_api_get \
  "/groups/$GROUP_ID/issues" \
  "created_after=$(urlencode "$SINCE_DATE")" \
  "per_page=100" \
  "order_by=created_at" \
  "sort=desc" >"$ISSUES_JSON_PATH"; then
  echo "Fehler: Die Issues für die Gruppe '$GROUP_INPUT' konnten nicht abgerufen werden." >&2
  exit 1
fi

if ! gitlab_api_get \
  "/groups/$GROUP_ID/merge_requests" \
  "state=merged" \
  "updated_after=$(urlencode "$SINCE_DATE")" \
  "per_page=100" \
  "order_by=updated_at" \
  "sort=desc" >"$MRS_JSON_PATH"; then
  echo "Fehler: Die Merge-Requests für die Gruppe '$GROUP_INPUT' konnten nicht abgerufen werden." >&2
  exit 1
fi

if ! gitlab_api_get \
  "/groups/$GROUP_ID/events" \
  "action=pushed" \
  "after=$(urlencode "$SINCE_DATE")" \
  "per_page=100" \
  "sort=desc" >"$COMMITS_JSON_PATH"; then
  echo "Fehler: Die Commit-Aktivität für die Gruppe '$GROUP_INPUT' konnte nicht abgerufen werden." >&2
  exit 1
fi

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

echo "Pulse-Daten wurden in $OUTPUT_PATH gespeichert"
