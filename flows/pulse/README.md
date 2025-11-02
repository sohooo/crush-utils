# Pulse Flow

Collect GitLab activity for a group and store it as a JSON snapshot that Crush can summarise later.

## Requirements
- `curl`
- `jq`
- GNU `date` (supports `-d`; e.g. `gdate` from coreutils on macOS should be linked as `date`)
- `GITLAB_TOKEN` exported with API access to the GitLab instance

Optional environment variables:
- `GITLAB_BASE_URL` (defaults to `https://gitlab.com`)
- `PULSE_DAYS` (defaults to `7`)

## Usage
```bash
./flows/pulse/pulse.sh [--output snapshot.json] <gitlab-group> [<gitlab-group> ...]
```
Examples:
```bash
export GITLAB_TOKEN=xxx
# Single group, default output path
./flows/pulse/pulse.sh platform
# Single group with custom output path
./flows/pulse/pulse.sh --output /tmp/apps-pulse.json apps
# Multiple groups with explicit output path
./flows/pulse/pulse.sh --output /tmp/multi-pulse.json platform apps infrastructure
```

The script resolves each group ID, fetches issues created, merge requests merged, and push events from the past `PULSE_DAYS` days, then saves them with handy counts:
```json
{
  "timeframe": {"since": "2024-05-01", "until": "2024-05-08T12:00:00Z"},
  "stats": {"issues": 12, "merge_requests": 25, "commits": 92},
  "groups": [
    {
      "group": {"id": 42, "full_path": "platform"},
      "timeframe": {"since": "2024-05-01", "until": "2024-05-08T12:00:00Z"},
      "stats": {"issues": 5, "merge_requests": 12, "commits": 48},
      "issues": [...],
      "merge_requests": [...],
      "commits": [...]
    },
    {
      "group": {"id": 99, "full_path": "apps"},
      "timeframe": {"since": "2024-05-01", "until": "2024-05-08T12:00:00Z"},
      "stats": {"issues": 7, "merge_requests": 13, "commits": 44},
      "issues": [...],
      "merge_requests": [...],
      "commits": [...]
    }
  ]
}
```

## Core Ideas from the Weekly Pulse Discussion
- Gather weekly GitLab activity (issues, merged MRs, commit pushes) per group through the REST API.
- Aggregate the JSON locally so Crush can analyse it without re-querying GitLab.
- Let Crush turn each snapshot into a leadership-friendly summary (Markdown works great).
- Optionally enrich with lightweight stats and publish the summary where your team reads it (Mattermost, GitLab wiki, etc.).
- Keep the snapshots so you can compare trendlines across weeks.
