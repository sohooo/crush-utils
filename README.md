# Crush Utils

Crush Utils is an idiomatic Ruby project that packages reusable automation flows
behind a simple command-line interface. Flows are organised under the
`Crush::Utils::Flows` namespace and are autoloaded with
[Zeitwerk](https://github.com/fxn/zeitwerk) so the file structure mirrors the
constant names. Generated artefacts and run logs live under `reports/` and
`log/` respectively.

## Getting started

```bash
bin/setup
```

This installs the gem dependencies declared in the gemspec.

To run a flow, use the CLI and provide the flow name. For example, the weekly
GitLab pulse report is exposed as `pulse.weekly`:

```bash
bin/crush-utils pulse.weekly
```

The CLI loads configuration from environment variables. You can populate a
project-level `.env` file with values and they will be loaded automatically when
needed. Required variables include:

- `GITLAB_BASE` – base URL of your GitLab instance (defaults to `https://gitlab.example.com`).
- `GITLAB_TOKEN` – personal access token with API access (mandatory).
- `GROUPS` – comma-separated list of GitLab groups to report on.
- `MATTERMOST_WEBHOOK` – optional webhook URL for publishing the overall summary.
- `PER_PAGE` – GitLab pagination size (defaults to `100`).

Generated reports are written to `reports/pulse/<year_week>/` and a JSON log is
stored at `log/pulse/weekly/<timestamp>.json`.

## Development

- `bin/console` opens an IRB session with the gem loaded.
- `bin/crush-utils --help` shows CLI usage information.

The project follows the standard Bundler layout so you can package it as a gem
if desired.
