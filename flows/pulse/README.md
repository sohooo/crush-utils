# Pulse Flow

Collect GitLab activity for a group and store it as a JSON snapshot that Crush can summarise later.

## Requirements
- `curl`
- `jq`
- GNU `date` (supports `-d`; e.g. `gdate` from coreutils on macOS should be linked as `date`)
- `GITLAB_TOKEN` environment variable with API access to the target group

Optional environment variables:
- `GITLAB_BASE_URL` (defaults to `https://gitlab.com`)
- `PULSE_DAYS` (defaults to `7`)

## Usage
```bash
./flows/pulse/pulse.sh gitlab-group-path [output-file]
```
Examples:
```bash
export GITLAB_TOKEN=xxx
./flows/pulse/pulse.sh platform
./flows/pulse/pulse.sh apps /tmp/apps-pulse.json
```

The script resolves the group ID, fetches issues created, merge requests merged, and push events from the past `PULSE_DAYS` days, then saves them with handy counts:
```json
{
  "group": {"id": 42, "full_path": "platform"},
  "timeframe": {"since": "2024-05-01", "until": "2024-05-08T12:00:00Z"},
  "stats": {"issues": 5, "merge_requests": 12, "commits": 48},
  "issues": [...],
  "merge_requests": [...],
  "commits": [...]
}
```

## Core Ideas from the Weekly Pulse Discussion
- Gather weekly GitLab activity (issues, merged MRs, commit pushes) per group through the REST API.
- Aggregate the JSON locally so Crush can analyse it without re-querying GitLab.
- Let Crush turn each snapshot into a leadership-friendly summary (Markdown works great).
- Optionally enrich with lightweight stats and publish the summary where your team reads it (Mattermost, GitLab wiki, etc.).
- Keep the snapshots so you can compare trendlines across weeks.
