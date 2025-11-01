#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <gitlab-merge-request-url>" >&2
  exit 1
fi

MR_URL="$1"

if ! command -v crush >/dev/null 2>&1; then
  echo "Error: the 'crush' CLI is not available in PATH." >&2
  exit 1
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat <<CONTEXT >"$TMP_DIR/merge_request.txt"
GitLab merge request URL:
$MR_URL
CONTEXT

export CRUSH_REVIEW_MR_URL="$MR_URL"
PROMPT="You are a senior engineer reviewing the GitLab merge request at $MR_URL. Use the provided context to summarise the proposal, highlight risks, and list clear follow-up actions."

env \
  CRUSH_CONTEXT_PATH="$TMP_DIR" \
  CRUSH_INITIAL_PROMPT="$PROMPT" \
  crush run flows/review_mr
