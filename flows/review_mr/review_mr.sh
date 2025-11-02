#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <gitlab-merge-request-url>" >&2
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
  echo "Error: unable to parse merge request URL '$MR_URL'." >&2
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
  echo "Error: failed to fetch merge request details from GitLab." >&2
  exit 1
fi

jq -r '
  def fmtdate: gsub("T"; " ") | sub("Z$"; " UTC");
  def fmt($value):
    ($value // "") as $raw |
    if $raw == "" then "n/a" else ($raw | fmtdate) end;
  "Title: \(.title // "(no title)")\n"
  + "URL: \(.web_url // "n/a")\n"
  + "Author: \(.author.name // "n/a") (@\(.author.username // "n/a"))\n"
  + "State: \(.state // "n/a")\n"
  + "Draft: \(if .draft then "yes" else "no" end)\n"
  + "Created: \(fmt(.created_at))\n"
  + "Updated: \(fmt(.updated_at))\n"
  + "Source branch: \(.source_branch // "n/a")\n"
  + "Target branch: \(.target_branch // "n/a")\n"
  + "Merge status: \(.detailed_merge_status // .merge_status // "n/a")\n"
  + "Approvals required: \((.approvals_before_merge // "n/a"))\n"
  + "\nDescription:\n"
  + (if (.description // "") == "" then "(no description provided)" else .description end)
' "$MR_OVERVIEW_JSON" >"$MR_OVERVIEW_TXT"

if ! gitlab_raw_get "$BASE_URL/$MR_PROJECT_PATH/-/merge_requests/$MR_IID.diff" >"$MR_DIFF_PATCH"; then
  echo "Error: failed to fetch merge request diff." >&2
  exit 1
fi

if gitlab_api_get \
  "/projects/$PROJECT_ENCODED/merge_requests/$MR_IID/commits" \
  "per_page=100" >"$MR_COMMITS_JSON"; then
    jq -r '
      def fmtdate: gsub("T"; " ") | sub("Z$"; " UTC");
      def fmt($value):
        ($value // "") as $raw |
        if $raw == "" then "n/a" else ($raw | fmtdate) end;
      if length == 0 then
        "No commits returned."
      else
        map("* \(.short_id) \(.title) (by \(.author_name // "unknown") on \(fmt(.created_at)))")
        | .[]
      end
  ' "$MR_COMMITS_JSON" >"$MR_COMMITS_TXT"
else
  echo "Warning: failed to fetch merge request commits." >&2
  : >"$MR_COMMITS_TXT"
fi

if ! gitlab_api_get \
  "/projects/$PROJECT_ENCODED/merge_requests/$MR_IID/discussions" \
  "per_page=100" \
  "order_by=created_at" \
  "sort=asc" >"$MR_DISCUSSIONS_JSON"; then
  echo "Warning: failed to fetch merge request discussions." >&2
fi

cat <<CONTEXT >"$(context_file merge_request.txt)"
GitLab merge request URL:
$MR_URL

Files captured for context:
- mr_overview.txt (metadata summary)
- mr_diff.patch (raw diff)
- mr_commits.txt (commit summaries)
- mr_discussions.json (raw discussion threads)

Raw API responses are also stored alongside the summaries for reference.
CONTEXT

export CRUSH_REVIEW_MR_URL="$MR_URL"

PROMPT="You are a senior engineer reviewing the GitLab merge request at $MR_URL. Use the collected GitLab API context to summarise the proposal, highlight risks, and list clear follow-up actions."

env \
  CRUSH_CONTEXT_PATH="$TMP_DIR" \
  CRUSH_INITIAL_PROMPT="$PROMPT" \
  crush run flows/review_mr
