#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Aufruf: $0 <gitlab-merge-request-url>" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"

# shellcheck source=../common.sh
source "$script_dir/../common.sh"

MR_URL="$1"

load_repo_env "$repo_dir"

require_commands crush curl jq

if [[ "$MR_URL" =~ ^(https?)://([^/]+)/(.+)/-/merge_requests/([0-9]+)(?:[^0-9].*)?$ ]]; then
  MR_SCHEME="${BASH_REMATCH[1]}"
  MR_HOST="${BASH_REMATCH[2]}"
  MR_PROJECT_PATH="${BASH_REMATCH[3]}"
  MR_IID="${BASH_REMATCH[4]}"
else
  echo "Fehler: Die Merge-Request-URL '$MR_URL' konnte nicht verarbeitet werden." >&2
  exit 1
fi

BASE_URL="$MR_SCHEME://$MR_HOST"

init_gitlab_api "$BASE_URL"

PROJECT_ENCODED="$(urlencode "$MR_PROJECT_PATH")"

context_file() {
  local name="$1"
  echo "$TMP_DIR/$name"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

MR_OVERVIEW_JSON="$(context_file mr_overview.json)"
MR_OVERVIEW_TXT="$(context_file mr_overview.txt)"
MR_DIFF_PATCH="$(context_file mr_diff.patch)"
MR_COMMITS_JSON="$(context_file mr_commits.json)"
MR_COMMITS_TXT="$(context_file mr_commits.txt)"
MR_DISCUSSIONS_JSON="$(context_file mr_discussions.json)"

if ! gitlab_api_get "/projects/$PROJECT_ENCODED/merge_requests/$MR_IID" >"$MR_OVERVIEW_JSON"; then
  echo "Fehler: Die Merge-Request-Details konnten nicht von GitLab abgerufen werden." >&2
  exit 1
fi

jq -r '
  def fmtdate: gsub("T"; " ") | sub("Z$"; " UTC");
  def fmt($value):
    ($value // "") as $raw |
    if $raw == "" then "k. A." else ($raw | fmtdate) end;
  "Titel: \(.title // "(kein Titel)")\n"
  + "URL: \(.web_url // "k. A.")\n"
  + "Autor: \(.author.name // "k. A.") (@\(.author.username // "k. A."))\n"
  + "Status: \(.state // "k. A.")\n"
  + "Entwurf: \(if .draft then "ja" else "nein" end)\n"
  + "Erstellt: \(fmt(.created_at))\n"
  + "Aktualisiert: \(fmt(.updated_at))\n"
  + "Quellbranch: \(.source_branch // "k. A.")\n"
  + "Zielbranch: \(.target_branch // "k. A.")\n"
  + "Merge-Status: \(.detailed_merge_status // .merge_status // "k. A.")\n"
  + "Benötigte Freigaben: \((.approvals_before_merge // "k. A."))\n"
  + "\nBeschreibung:\n"
  + (if (.description // "") == "" then "(keine Beschreibung angegeben)" else .description end)
' "$MR_OVERVIEW_JSON" >"$MR_OVERVIEW_TXT"

if ! gitlab_raw_get "$BASE_URL/$MR_PROJECT_PATH/-/merge_requests/$MR_IID.diff" >"$MR_DIFF_PATCH"; then
  echo "Fehler: Der Merge-Request-Diff konnte nicht abgerufen werden." >&2
  exit 1
fi

if gitlab_api_get \
  "/projects/$PROJECT_ENCODED/merge_requests/$MR_IID/commits" \
  "per_page=100" >"$MR_COMMITS_JSON"; then
    jq -r '
      def fmtdate: gsub("T"; " ") | sub("Z$"; " UTC");
      def fmt($value):
        ($value // "") as $raw |
        if $raw == "" then "k. A." else ($raw | fmtdate) end;
      if length == 0 then
        "Keine Commits zurückgegeben."
      else
        map("* \(.short_id) \(.title) (von \(.author_name // "unbekannt") am \(fmt(.created_at)))")
        | .[]
      end
  ' "$MR_COMMITS_JSON" >"$MR_COMMITS_TXT"
else
  echo "Warnung: Die Merge-Request-Commits konnten nicht abgerufen werden." >&2
  : >"$MR_COMMITS_TXT"
fi

if ! gitlab_api_get \
  "/projects/$PROJECT_ENCODED/merge_requests/$MR_IID/discussions" \
  "per_page=100" \
  "order_by=created_at" \
  "sort=asc" >"$MR_DISCUSSIONS_JSON"; then
  echo "Warnung: Die Merge-Request-Diskussionen konnten nicht abgerufen werden." >&2
fi

cat <<CONTEXT >"$(context_file merge_request.txt)"
GitLab-Merge-Request-URL:
$MR_URL

Für den Kontext erfasste Dateien:
- mr_overview.txt (Metadaten-Zusammenfassung)
- mr_diff.patch (roher Diff)
- mr_commits.txt (Commit-Zusammenfassungen)
- mr_discussions.json (rohe Diskussionsverläufe)

Die Rohantworten der API werden ebenfalls zur Referenz gespeichert.
CONTEXT

export CRUSH_REVIEW_MR_URL="$MR_URL"

PROMPT="Du bist eine erfahrene Ingenieurin bzw. ein erfahrener Ingenieur und prüfst den GitLab-Merge-Request unter $MR_URL. Nutze den zusammengestellten GitLab-API-Kontext, um den Vorschlag zusammenzufassen, Risiken hervorzuheben und konkrete Folgeaktionen aufzulisten."

env \
  CRUSH_CONTEXT_PATH="$TMP_DIR" \
  CRUSH_INITIAL_PROMPT="$PROMPT" \
  crush run flows/review_mr
