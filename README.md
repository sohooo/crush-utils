# Crush Utilities

This repository contains Crush flows for GitLab-focused workflows.

## Available Flows

### Merge Request Review
Use the helper script to review a GitLab merge request with Crush:

```bash
./flows/review_mr/review_mr.sh "https://gitlab.com/your/project/-/merge_requests/123"
```
The script loads environment defaults, stages the merge-request URL as context, and launches the `flows/review_mr` Crush pipeline.

### Weekly Pulse Snapshot
Generate a JSON snapshot of recent GitLab activity for a group:

```bash
export GITLAB_TOKEN=xxx
./flows/pulse/pulse.sh your-group-path
```
The script queries issues created, merge requests merged, and push events from the last seven days (configurable with `PULSE_DAYS`) and writes a ready-to-summarise JSON file.

See each flow's README under `flows/<flow-name>/` for full details.
