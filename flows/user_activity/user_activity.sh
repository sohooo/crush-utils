#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE >&2
Aufruf: $0 <gitlab-nutzername> [tage]

Umgebungsvariablen:
  GITLAB_BASE_URL   Basis-URL der GitLab-Instanz (Standard: https://gitlab.com)
  GITLAB_TOKEN      Personal Access Token mit API-Rechten
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
  echo "Fehler: Die Anzahl der Tage muss eine Ganzzahl sein (erhalten: '$DAYS')." >&2
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
  echo "Fehler: Der GitLab-Nutzende '$USERNAME' konnte nicht ermittelt werden." >&2
  exit 1
fi

USER_ID="$(jq -r '.[0].id // empty' "$USER_JSON_PATH")"

if [[ -z "$USER_ID" ]]; then
  echo "Fehler: Der GitLab-Nutzende '$USERNAME' wurde nicht gefunden." >&2
  exit 1
fi

NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
if ! SINCE_UTC="$(date -u -d "${DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)"; then
  echo "Fehler: GNU date wird benötigt (Unterstützung für \"-d\" fehlt)." >&2
  exit 1
fi

if ! gitlab_api_get \
  "/users/$USER_ID/events" \
  "after=$(urlencode "$SINCE_UTC")" \
  "per_page=100" \
  "sort=desc" >"$EVENTS_JSON_PATH"; then
  echo "Fehler: Die Aktivitäten für '$USERNAME' konnten nicht abgerufen werden." >&2
  exit 1
fi

USER_NAME="$(jq -r '.[0].name // .[0].username' "$USER_JSON_PATH")"

cat <<CONTEXT >"$OVERVIEW_PATH"
Erfasste GitLab-Nutzeraktivität
===============================

Nutzer: $USER_NAME (@$USERNAME)
Zeitraum: letzte $DAYS Tag(e) ($SINCE_UTC bis $NOW_UTC)

Dateien in diesem Kontextverzeichnis:
- user.json: Rohantwort der Nutzersuche
- events_raw.json: Rohe Ereignisse der GitLab-API

Nutze diese Artefakte, um die jüngsten GitLab-Aktivitäten der Person prägnant zusammenzufassen, wichtige Beiträge hervorzuheben und eventuelle Folgeaufgaben zu markieren. Greife für Details direkt auf die rohen Ereignisse zu.
CONTEXT

PROMPT="Du bist eine technische Führungskraft und bewertest die GitLab-Aktivitäten von @$USERNAME der vergangenen $DAYS Tag(e). Nutze die bereitgestellten rohen GitLab-Ereignisse, um zentrale Beiträge, Themen und empfohlene Folgeaktionen zu beschreiben. Sei nach Möglichkeit konkret bei Repositories, Merge-Requests und Issues."

export CRUSH_USER_ACTIVITY_USERNAME="$USERNAME"
export CRUSH_USER_ACTIVITY_DAYS="$DAYS"

env \
  CRUSH_CONTEXT_PATH="$TMP_DIR" \
  CRUSH_INITIAL_PROMPT="$PROMPT" \
  crush run flows/user_activity
