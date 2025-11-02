#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE >&2
Usage: $0 [--output <file>] <gitlab-group-path-or-id> [<gitlab-group-path-or-id> ...]

Environment variables:
  GITLAB_BASE_URL   Base URL of the GitLab instance (default: https://gitlab.com)
  GITLAB_TOKEN      Personal access token with API scope
  PULSE_DAYS        Number of days to include in the snapshot (default: 7)
USAGE
}

OUTPUT_PATH=""
GROUP_INPUTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      if [[ $# -lt 2 ]]; then
        echo "Error: --output requires a path." >&2
        usage
        exit 1
      fi
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      GROUP_INPUTS+=("$@")
      break
      ;;
    -* )
      echo "Error: unknown option '$1'." >&2
      usage
      exit 1
      ;;
    * )
      GROUP_INPUTS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#GROUP_INPUTS[@]} -eq 0 ]]; then
  usage
  exit 1
fi

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
  echo "Error: PULSE_DAYS must be an integer (received '$DAYS')." >&2
  exit 1
fi

NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if ! SINCE_DATE="$(date -u -d "${DAYS} days ago" +"%Y-%m-%d" 2>/dev/null)"; then
  echo "Error: GNU date is required (missing \"-d\" support)." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RESULT_FILES=()

for GROUP_INPUT in "${GROUP_INPUTS[@]}"; do
  GROUP_TMP_DIR="$TMP_DIR/$(printf 'group-%s' "${#RESULT_FILES[@]}")"
  mkdir -p "$GROUP_TMP_DIR"

  GROUP_JSON_PATH="$GROUP_TMP_DIR/group.json"
  ISSUES_JSON_PATH="$GROUP_TMP_DIR/issues.json"
  MRS_JSON_PATH="$GROUP_TMP_DIR/mrs.json"
  COMMITS_JSON_PATH="$GROUP_TMP_DIR/commits.json"

  GROUP_ENCODED="$(urlencode "$GROUP_INPUT")"

  if ! gitlab_api_get "/groups/$GROUP_ENCODED" >"$GROUP_JSON_PATH"; then
    echo "Error: unable to resolve group '$GROUP_INPUT'." >&2
    exit 1
  fi

  GROUP_ID="$(jq -r '.id' "$GROUP_JSON_PATH")"

  if [[ -z "$GROUP_ID" || "$GROUP_ID" == "null" ]]; then
    echo "Error: unable to resolve group '$GROUP_INPUT'." >&2
    exit 1
  fi

  if ! gitlab_api_get \
    "/groups/$GROUP_ID/issues" \
    "created_after=$(urlencode "$SINCE_DATE")" \
    "per_page=100" \
    "order_by=created_at" \
    "sort=desc" >"$ISSUES_JSON_PATH"; then
    echo "Error: failed to fetch issues for group '$GROUP_INPUT'." >&2
    exit 1
  fi

  if ! gitlab_api_get \
    "/groups/$GROUP_ID/merge_requests" \
    "state=merged" \
    "updated_after=$(urlencode "$SINCE_DATE")" \
    "per_page=100" \
    "order_by=updated_at" \
    "sort=desc" >"$MRS_JSON_PATH"; then
    echo "Error: failed to fetch merge requests for group '$GROUP_INPUT'." >&2
    exit 1
  fi

  if ! gitlab_api_get \
    "/groups/$GROUP_ID/events" \
    "action=pushed" \
    "after=$(urlencode "$SINCE_DATE")" \
    "per_page=100" \
    "sort=desc" >"$COMMITS_JSON_PATH"; then
    echo "Error: failed to fetch commit activity for group '$GROUP_INPUT'." >&2
    exit 1
  fi

  RESULT_PATH="$GROUP_TMP_DIR/result.json"

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
    }' >"$RESULT_PATH"

  RESULT_FILES+=("$RESULT_PATH")
done

GROUP_COUNT=${#GROUP_INPUTS[@]}

if [[ -z "$OUTPUT_PATH" ]]; then
  if [[ $GROUP_COUNT -eq 1 ]]; then
    SAFE_GROUP="${GROUP_INPUTS[0]//\//-}"
    OUTPUT_PATH="pulse-${SAFE_GROUP}-$(date +%Y-%m-%d).json"
  else
    OUTPUT_PATH="pulse-groups-$(date +%Y-%m-%d).json"
  fi
fi

if [[ $GROUP_COUNT -eq 1 ]]; then
  cp "${RESULT_FILES[0]}" "$OUTPUT_PATH"
else
  jq -s \
    --arg since "$SINCE_DATE" \
    --arg until "$NOW_UTC" \
    '{
      timeframe: { since: $since, until: $until },
      stats: {
        issues: (map(.stats.issues // 0) | add),
        merge_requests: (map(.stats.merge_requests // 0) | add),
        commits: (map(.stats.commits // 0) | add)
      },
      groups: .
    }' "${RESULT_FILES[@]}" >"$OUTPUT_PATH"
fi

echo "Saved pulse data to $OUTPUT_PATH"
