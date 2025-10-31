#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)

# Load shared configuration when required
if [[ -z "${GITLAB_BASE:-}" || -z "${GITLAB_TOKEN:-}" || -z "${GROUPS:-}" || -z "${MATTERMOST_WEBHOOK:-}" ]]; then
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    source "${REPO_ROOT}/.env"
    set +a
  fi
fi

# ====== CONFIG ======
: "${GITLAB_BASE:=https://gitlab.example.com}"   # your GitLab base URL
: "${GITLAB_TOKEN:?Set GITLAB_TOKEN via the environment or .env file}"
: "${GROUPS:=dbsys}"                             # space-separated list, e.g. "dbsys platform apps"
: "${OUT_ROOT:=${SCRIPT_DIR}/reports}"
: "${CRUSH_CONFIG:=${SCRIPT_DIR}/.crush/lead.crush.json}"
: "${MATTERMOST_WEBHOOK:=}"                      # optional: if set, post overall summary
: "${PER_PAGE:=100}"
: "${DATE_CMD:=date}"

# Window = ISO week folder like 2025_41 (Mon..Sun). Requires GNU date.
# If on macOS, install coreutils and use gdate.
YEAR_WEEK="$(${DATE_CMD} +%G_%V)"
WEEK_START="$(${DATE_CMD} -d 'last monday' +%F 2>/dev/null || ${DATE_CMD} -v-mon +%F)"
WEEK_END="$(${DATE_CMD} -d 'next monday' +%F 2>/dev/null || ${DATE_CMD} -v+mon +%F)"

OUT_DIR="${OUT_ROOT}/${YEAR_WEEK}"
mkdir -p "${OUT_DIR}"

echo "▶ Weekly window: ${WEEK_START} .. ${WEEK_END}  →  ${OUT_DIR}"
echo "▶ Groups: ${GROUPS}"

# ====== HELPERS ======
hdr=(-H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

api_get() {
  # $1 = path (starting with /api/v4/...), $2.. = curl extra args
  curl -sS "${hdr[@]}" "$@" "${GITLAB_BASE}$1"
}

# Paginate through GitLab endpoints that use Link / X-Next-Page headers
paginate() {
  local url="$1"
  shift
  local page=1
  local out="[]"
  while :; do
    local resp headers next
    resp=$(curl -sS -D >(headers=$(cat); printf "%s" "$headers" > /tmp/headers.$$) "${hdr[@]}" "$@" "${url}&per_page=${PER_PAGE}&page=${page}")
    # Merge arrays (if resp is array) or wrap into array
    if jq -e . >/dev/null 2>&1 <<<"$resp"; then
      if [[ "$(jq -r 'type' <<<"$resp")" == "array" ]]; then
        out=$(jq -s '.[0] + .[1]' <(printf '%s' "$out") <(printf '%s' "$resp"))
      else
        out=$(jq -s '.[0] + [.[1]]' <(printf '%s' "$out") <(printf '%s' "$resp"))
      fi
    fi
    next=$(grep -Fi 'X-Next-Page' /tmp/headers.$$ | awk -F': ' '{print $2}' | tr -d '\r')
    [[ -z "${next}" ]] && break
    page="${next}"
  done
  printf '%s' "$out"
}

slugify() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g;s/^-|-$//g'; }

group_id_by_path() {
  local path="$1"
  api_get "/api/v4/groups/${path}"
}

list_group_projects() {
  local gid="$1"
  paginate "${GITLAB_BASE}/api/v4/groups/${gid}/projects?include_subgroups=true&with_shared=true"
}

# ====== FETCH PER-GROUP ======
fetch_group_activity() {
  local group="$1"
  local gslug; gslug=$(slugify "$group")
  local gdir="${OUT_DIR}/${gslug}"
  mkdir -p "${gdir}/raw" "${gdir}/stats"

  echo "→ Fetching group '${group}'"
  local gjson gid
  gjson=$(group_id_by_path "$group")
  gid=$(jq -r '.id' <<<"$gjson")

  # List projects
  local projects; projects=$(list_group_projects "$gid")
  printf '%s' "$projects" > "${gdir}/raw/projects.json"

  # Issues & MRs updated in window (group-scoped)
  api_get "/api/v4/groups/${gid}/issues?updated_after=${WEEK_START}T00:00:00Z&updated_before=${WEEK_END}T00:00:00Z&scope=all&state=opened" > "${gdir}/raw/issues.json"
  api_get "/api/v4/groups/${gid}/merge_requests?updated_after=${WEEK_START}T00:00:00Z&updated_before=${WEEK_END}T00:00:00Z&scope=all" > "${gdir}/raw/mrs.json"

  # Project-scoped: commits, pipelines, events (pushes)
  jq -r '.[].id' "${gdir}/raw/projects.json" | while read -r pid; do
    # Commits in window
    paginate "${GITLAB_BASE}/api/v4/projects/${pid}/repository/commits?since=${WEEK_START}T00:00:00Z&until=${WEEK_END}T00:00:00Z" > "${gdir}/raw/${pid}-commits.json"
    # Pipelines updated in window
    paginate "${GITLAB_BASE}/api/v4/projects/${pid}/pipelines?updated_after=${WEEK_START}T00:00:00Z&updated_before=${WEEK_END}T00:00:00Z" > "${gdir}/raw/${pid}-pipelines.json"
    # Events (pushes etc.)
    paginate "${GITLAB_BASE}/api/v4/projects/${pid}/events?after=${WEEK_START}&before=${WEEK_END}" > "${gdir}/raw/${pid}-events.json"
  done

  # ====== AGGREGATE ======
  # Collapse commits/pipelines/events into arrays
  jq -s 'flatten' "${gdir}"/raw/*-commits.json > "${gdir}/raw/commits.all.json"
  jq -s 'flatten' "${gdir}"/raw/*-pipelines.json > "${gdir}/raw/pipelines.all.json"
  jq -s 'flatten' "${gdir}"/raw/*-events.json > "${gdir}/raw/events.all.json"

  # Compute quick stats
  jq '{count: length, authors: (group_by(.author_name)|map({name: (.[0].author_name), commits: length})|sort_by(-.commits))}' "${gdir}/raw/commits.all.json" > "${gdir}/stats/commits.json"
  jq '{count: length, merged: (map(select(.status=="success"))|length), failed: (map(select(.status=="failed"))|length)}' "${gdir}/raw/pipelines.all.json" > "${gdir}/stats/pipelines.json"
  jq '{open_or_updated: length}' "${gdir}/raw/issues.json" > "${gdir}/stats/issues.json"
  jq '{updated: length, merged: (map(select(.merged_at!=null))|length)}' "${gdir}/raw/mrs.json" > "${gdir}/stats/mrs.json"

  # Build a single group aggregate
  jq -n --arg group "$group" --arg start "$WEEK_START" --arg end "$WEEK_END" \
     --slurpfile projects "${gdir}/raw/projects.json" \
     --slurpfile issues "${gdir}/raw/issues.json" \
     --slurpfile mrs "${gdir}/raw/mrs.json" \
     --slurpfile commits "${gdir}/raw/commits.all.json" \
     --slurpfile pipelines "${gdir}/raw/pipelines.all.json" \
     --slurpfile events "${gdir}/raw/events.all.json" \
     '{
        group: $group,
        window: { since: $start, until: $end },
        projects: $projects[0],
        issues: $issues[0],
        merge_requests: $mrs[0],
        commits: $commits[0],
        pipelines: $pipelines[0],
        events: $events[0]
      }' > "${gdir}/group_aggregate.json"

  # ====== SUMMARIZE WITH CRUSH ======
  local summary="${gdir}/summary.md"
  crush --config "${CRUSH_CONFIG}" --yolo -c "
Read '${gdir}/group_aggregate.json'.
Produce a weekly summary for the GitLab group '${group}' (${WEEK_START}..${WEEK_END}).
Focus on:
- **Highlights & themes** across issues/MRs/commits
- **Top MRs** (impact, risk) and notable projects
- **Contributors** (from commits) with brief impact notes
- **CI health** from pipelines (failures vs successes, flaky signals if any)
- **Trends** vs previous week if signals exist in this file path (compare counts)
- **Risks & blockers**
- **Suggested focus for next week**

Format Markdown with sections and concise bullets. Avoid speculation; cite counts where available.
" > "${summary}"

  echo "✓ Group summary: ${summary}"
}

# ====== MAIN ======
# Fetch per-group & keep list of aggregates to build an overall picture.
aggregates=()
for grp in ${GROUPS}; do
  fetch_group_activity "${grp}"
  aggregates+=("${OUT_DIR}/$(slugify "${grp}")/group_aggregate.json")
done

# ====== OVERALL SUMMARY ======
overall_json="${OUT_DIR}/overall_aggregate.json"
jq -s '{
  window: { since: "'"${WEEK_START}"'", until: "'"${WEEK_END}"'" },
  groups: .
}' "${aggregates[@]}" > "${overall_json}"

overall_md="${OUT_DIR}/overall_summary.md"
crush --config "${CRUSH_CONFIG}" --yolo -c "
Read '${overall_json}'.
Create an **Overall Weekly Engineering Pulse** that synthesizes all groups:
- **Org-wide highlights**
- **Cross-cutting themes**
- **Top contributors** (org-wide), mention group/project briefly
- **CI health** (roll-up)
- **Hotspots** (repos/modules with high churn or failing pipelines)
- **Risks & decisions needed**
- **Next-week priorities** (3–5 bullets)
Use crisp Markdown. Add a short KPI table (counts per group: issues updated, MRs updated/merged, commits, pipelines success/fail).
" > "${overall_md}"

echo "✓ Overall summary: ${overall_md}"

# Optional: post overall summary to Mattermost
if [[ -n "${MATTERMOST_WEBHOOK}" ]]; then
  # shellcheck disable=SC2002
  payload=$(cat "${overall_md}" | jq -Rs '{text: .}')
  curl -sS -X POST -H 'Content-Type: application/json' -d "${payload}" "${MATTERMOST_WEBHOOK}" >/dev/null && \
    echo "✓ Posted to Mattermost"
fi

echo "✅ Done."
