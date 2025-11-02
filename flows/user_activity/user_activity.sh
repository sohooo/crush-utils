#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE >&2
Usage: $0 <gitlab-username> [days]

Environment variables:
  GITLAB_BASE_URL   Base URL of the GitLab instance (default: https://gitlab.com)
  GITLAB_TOKEN      Personal access token with API scope (if not authenticated via glab)
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

if ! command -v crush >/dev/null 2>&1; then
  echo "Error: the 'crush' CLI is not available in PATH." >&2
  exit 1
fi

if ! command -v glab >/dev/null 2>&1; then
  echo "Error: the 'glab' CLI is not available in PATH." >&2
  echo "Install it from https://gitlab.com/gitlab-org/cli#installation" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: the 'jq' CLI is required." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

USERNAME="$1"
DAYS="${2:-7}"

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: days must be an integer (received '$DAYS')." >&2
  exit 1
fi

BASE_URL="${GITLAB_BASE_URL:-https://gitlab.com}"

if [[ -f "$REPO_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_DIR/.env"
  set +a
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

GLAB_HOSTNAME="${BASE_URL#*://}"
GLAB_HOSTNAME="${GLAB_HOSTNAME%%/}"

GLAB_ARGS=(api)
if [[ -n "$GLAB_HOSTNAME" ]]; then
  GLAB_ARGS+=(--hostname "$GLAB_HOSTNAME")
fi

glab_api() {
  glab "${GLAB_ARGS[@]}" "$@"
}

GLAB_STATUS_ARGS=()
if [[ -n "$GLAB_HOSTNAME" ]]; then
  GLAB_STATUS_ARGS+=(--hostname "$GLAB_HOSTNAME")
fi

if ! glab auth status "${GLAB_STATUS_ARGS[@]}" >/dev/null 2>&1; then
  if [[ -z "${GITLAB_TOKEN:-}" ]]; then
    echo "Error: glab is not authenticated. Run 'glab auth login' or set GITLAB_TOKEN." >&2
    exit 1
  fi
fi

USER_JSON_PATH="$TMP_DIR/user.json"
EVENTS_JSON_PATH="$TMP_DIR/events_raw.json"
SUMMARY_JSON_PATH="$TMP_DIR/activity_summary.json"
EVENTS_TEXT_PATH="$TMP_DIR/events.txt"
OVERVIEW_PATH="$TMP_DIR/context_overview.txt"

if ! glab_api \
  --field "username=$USERNAME" \
  "/users" >"$USER_JSON_PATH"; then
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

if ! glab_api \
  --field "after=$SINCE_UTC" \
  --field "per_page=100" \
  --field "sort=desc" \
  --paginate \
  "/users/$USER_ID/events" >"$EVENTS_JSON_PATH"; then
  echo "Error: failed to fetch activity for user '$USERNAME'." >&2
  exit 1
fi

jq -n \
  --slurpfile user "$USER_JSON_PATH" \
  --slurpfile events "$EVENTS_JSON_PATH" \
  --arg since "$SINCE_UTC" \
  --arg until "$NOW_UTC" \
  '
    ($user[0][0]) as $u |
    {
      user: {
        id: $u.id,
        username: $u.username,
        name: $u.name,
        state: $u.state,
        web_url: $u.web_url,
        bio: $u.bio,
        location: $u.location,
        organization: $u.organization
      },
      timeframe: { since: $since, until: $until },
      stats: (reduce $events[0][] as $e (
        { total_events: 0, actions: {}, target_types: {} };
        .total_events += 1 |
        .actions[$e.action_name // "unknown"] = (.actions[$e.action_name // "unknown"] // 0) + 1 |
        .target_types[($e.target_type // "none")] = (.target_types[($e.target_type // "none")] // 0) + 1
      )),
      events: $events[0]
    }
  ' >"$SUMMARY_JSON_PATH"

jq -r '
  def action_line($e):
    (
      ($e.created_at // "unknown time") + " | " +
      ($e.action_name // "event") +
      (if $e.target_type then " " + $e.target_type else "" end) +
      (if $e.target_title then ": " + ($e.target_title | tostring) else "" end) +
      (if $e.push_data and $e.push_data.commit_count then " (" + ($e.push_data.commit_count | tostring) + " commits)" else "" end)
    );
  def note_block($e):
    if $e.note then "    Note: " + ($e.note | gsub("\n"; " ")) else empty end;
  if length == 0 then
    "No GitLab events found for the selected timeframe."
  else
    ("Recent GitLab events:"),
    (map(. as $event | action_line($event) +
        (if $event.note then "\n" + note_block($event) else "" end)
      ))[]
  end
' "$EVENTS_JSON_PATH" >"$EVENTS_TEXT_PATH"

USER_NAME="$(jq -r '.[0].name // .[0].username' "$USER_JSON_PATH")"

cat <<CONTEXT >"$OVERVIEW_PATH"
GitLab user activity capture
============================

User: $USER_NAME (@$USERNAME)
Timeframe: last $DAYS day(s) ($SINCE_UTC to $NOW_UTC)

Files included in this context directory:
- user.json: Raw response for the user lookup
- events_raw.json: Raw events returned by the GitLab API
- activity_summary.json: Structured summary and counts
- events.txt: Human-readable event log

Use these artefacts to produce a concise summary of the user's recent GitLab activity, highlight notable contributions, and flag any follow-ups.
CONTEXT

PROMPT="You are an engineering lead reviewing recent GitLab activity for @$USERNAME over the past $DAYS day(s). Use the provided JSON summaries and event log to describe key contributions, themes, and recommended follow-ups. Be specific about repositories, merge requests, and issues where possible."

export CRUSH_USER_ACTIVITY_USERNAME="$USERNAME"
export CRUSH_USER_ACTIVITY_DAYS="$DAYS"

env \
  CRUSH_CONTEXT_PATH="$TMP_DIR" \
  CRUSH_INITIAL_PROMPT="$PROMPT" \
  crush run flows/user_activity
