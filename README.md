# Crush Merge Request Reviewer

This repository contains a Crush flow that reviews GitLab merge requests using the `flows/review_mr` configuration.

## Usage

1. Ensure the [`crush`](https://github.com/crush-tools/crush) CLI is available in your `PATH` and configure any provider credentials in `.env`.
2. Run the helper script with the merge request URL:

```bash
./flows/review_mr/review_mr.sh "https://gitlab.com/your/project/-/merge_requests/123"
```

The script loads environment defaults, stages the merge-request URL as context, and launches the `flows/review_mr` Crush pipeline.
