# Crush Utils

Reusable automations and supporting assets for running Charm's Crush workflows. Each flow lives under `flows/<name>` so it can bundle scripts, configuration, and documentation in one place.

## Available flows

### Pulse (GitLab weekly reports)
- Location: `flows/pulse`
- Generates weekly GitLab group activity summaries (per-group and overall) using the shared `.env` configuration, GitLab APIs, and Crush for automated write-ups.
- Run with `./flows/pulse/weekly-pulse.sh` after populating `.env` with your GitLab credentials (keep real tokens out of source control).

More flows will be added over time, reusing the same global `.env` file for shared environment variables.
