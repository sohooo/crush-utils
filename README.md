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

### GitLab merge request reviewer

The merge request reviewer flow analyses a GitLab MR end-to-end, cloning the
project, fetching the merge request branch, and producing an actionable review
written in Markdown. Invoke it with the merge request URL:

```bash
bin/crush-utils gitlab.mr_reviewer https://gitlab.example.com/group/project/-/merge_requests/123
```

The flow requires `GITLAB_TOKEN` to access the GitLab API (values can be loaded
from `.env` as described above). Optional environment variables include
`PER_PAGE` for API pagination and `GIT_EXECUTABLE` when a non-default `git`
binary should be used. By default the flow uses the prompt configuration stored
under `lib/crush/utils/flows/gitlab/.crush/mr_reviewer.crush.json`; set
`CRUSH_CONTEXT_PATH` and other `CRUSH_*` variables expected by your environment
so the `crush` CLI can run successfully.

Outputs live under `reports/gitlab/mr_reviews/<project-slug>/mr-<iid>/` and
include:

- `raw/` – snapshots of the project, merge request, and change metadata fetched
  from the GitLab API.
- `<project-slug>-mr-<iid>.diff` – unified diff generated locally between the
  target branch and the merge request head.
- `<project-slug>-mr-<iid>-aggregate.json` – aggregated metadata consumed by the
  reviewer prompt.
- `<project-slug>-mr-<iid>.md` – the rendered review containing summary, risk
  analysis, security/performance call-outs, and recommended actions.
- `<project-slug>-mr-<iid>.json` – structured log capturing the inputs and
  outputs for the run.

A working copy of the repository is cloned into
`reports/gitlab/mr_reviews/<project-slug>/mr-<iid>/repo/` for context while the
flow executes.

## Development

- `bin/console` opens an IRB session with the gem loaded.
- `bin/crush-utils --help` shows CLI usage information.

The project follows the standard Bundler layout so you can package it as a gem
if desired.
