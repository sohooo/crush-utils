# Pulse Flow

This directory contains the "pulse" automation, which produces weekly GitLab activity summaries and is the first entry in our library of reusable flows. Future flows should live alongside this one so that shared assets (.env, docs, configs) remain easy to discover.

## Layout

- `.crush/lead.crush.json` – Crush persona/provider configuration used by the summarisation steps.
- `.crushignore` – ignores large/generated artefacts when sending context to Crush.
- `weekly-pulse.rb` – end-to-end Ruby script that fetches GitLab data, assembles aggregates, and drafts Markdown reports while logging each run.
- `reports/` – created on demand; holds generated weekly output (ignored until populated).

## Usage

1. Update the repository-level `.env` with your GitLab URL, token, and default groups (see the root README for details).
2. Ensure Crush is installed locally with access to the configured provider.
3. Run `ruby ./flows/pulse/weekly-pulse.rb` (from the repo root) to create `flows/pulse/reports/<year_week>/` containing group summaries, the overall pulse, and a corresponding log entry. Override any environment variables inline if you need to customise a run.

The script automatically loads the shared `.env` file but still honours variables exported in your shell when you need per-run overrides (for example, `GROUPS="dbsys apps" ruby ./flows/pulse/weekly-pulse.rb`).
