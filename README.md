# Crush Utilities

This repository contains Crush flows for GitLab-focused workflows.

## Available Flows

### Merge Request Review
Use the helper script to review a GitLab merge request with Crush. The script requires both the [`crush`](https://github.com/crush-org/crush) and [`glab`](https://gitlab.com/gitlab-org/cli) CLIs in your `PATH`:

```bash
./flows/review_mr/review_mr.sh "https://gitlab.com/your/project/-/merge_requests/123"
```
The script loads environment defaults, stages the merge-request URL as context, and launches the `flows/review_mr` Crush pipeline.

### Weekly Pulse Snapshot
Generate a JSON snapshot of recent GitLab activity for a group (requires `curl`, `jq`, and GNU `date`):

```bash
export GITLAB_TOKEN=xxx
./flows/pulse/pulse.sh your-group-path
```
The script queries issues created, merge requests merged, and push events from the last seven days (configurable with `PULSE_DAYS`) and writes a ready-to-summarise JSON file.

See each flow's README under `flows/<flow-name>/` for full details.

### User Activity Overview
Collect recent GitLab events for a specific user and launch Crush to summarise the highlights:

```bash
./flows/user_activity/user_activity.sh username [days]
```

The script resolves the user, gathers activity from the past `days` (default `7`), stages structured JSON and text context, then opens the `flows/user_activity` Crush pipeline to produce a concise activity report.
