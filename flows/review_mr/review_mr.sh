#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <gitlab-merge-request-url>" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"

MR_URL="$1"

if ! command -v crush >/dev/null 2>&1; then
  echo "Error: the 'crush' CLI is not available in PATH." >&2
  exit 1
fi

if ! command -v glab >/dev/null 2>&1; then
  echo "Error: the 'glab' CLI is not available in PATH." >&2
  echo "Install it from https://gitlab.com/gitlab-org/cli#installation" >&2
  exit 1
fi

if [[ -f "$repo_dir/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$repo_dir/.env"
  set +a
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$repo_dir"

if [[ "$MR_URL" =~ /-/merge_requests/([0-9]+) ]]; then
  MR_REF="${BASH_REMATCH[1]}"
else
  MR_REF="$MR_URL"
fi

context_file() {
  local name="$1"
  echo "$TMP_DIR/$name"
}

set +e
glab mr view "$MR_REF" --comments >"$(context_file mr_overview.txt)"
VIEW_STATUS=$?
glab mr diff "$MR_REF" >"$(context_file mr_diff.patch)"
DIFF_STATUS=$?
glab mr commits "$MR_REF" >"$(context_file mr_commits.txt)"
COMMITS_STATUS=$?
set -e

if [[ $VIEW_STATUS -ne 0 || $DIFF_STATUS -ne 0 ]]; then
  echo "Error: failed to collect merge request details with glab." >&2
  exit 1
fi

if [[ $COMMITS_STATUS -ne 0 ]]; then
  echo "Warning: could not collect commit summaries with glab." >&2
fi

cat <<CONTEXT >"$(context_file merge_request.txt)"
GitLab merge request URL:
$MR_URL

Files captured for context:
- mr_overview.txt (metadata and discussion)
- mr_diff.patch (full diff)
- mr_commits.txt (commit summaries)
CONTEXT

export CRUSH_REVIEW_MR_URL="$MR_URL"

PROMPT="You are a senior engineer reviewing the GitLab merge request at $MR_URL. Use the collected glab context to summarise the proposal, highlight risks, and list clear follow-up actions."

env \
  CRUSH_CONTEXT_PATH="$TMP_DIR" \
  CRUSH_INITIAL_PROMPT="$PROMPT" \
  crush run flows/review_mr
