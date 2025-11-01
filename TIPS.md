# Crush Power-User Tips

## 1. Session System
- Use `crush sessions` to list, create, switch, and delete sessions.
- Keep per-feature sessions so context persists without re-priming.

## 2. Provider Architecture
- Swap providers on demand (`crush providers`, `crush switch-provider`).
- Within a session, `/switch model <id>` lets you mix fast and deep models.

## 3. LSP Integration
- Configure `.crush.json` `lsp` entries to tap language servers for symbols and docs.
- Enable `debug_lsp: true` to inspect the exact snippets sent to the model.

## 4. MCP Support
- Define `mcp` blocks to attach stdio, HTTP, or SSE tools (filesystem, GitHub, CI, DB, etc.).
- Grants the model programmable access to your environment.

## 5. Context Control
- Curate `context_paths` and ignores to keep context focused.
- Use inline `/grep` or shell `grep` to pull relevant snippets into the conversation.

## 6. Tool Permissions & Safety
- Whitelist tools via `permissions.allowed_tools`; use `--yolo` sparingly for unattended loops.

## 7. Ephemeral State & Logs
- Session state lives in `~/.local/share/crush/crush.json`; logs live in `.crush/logs/`.
- Monitor with `crush logs` or `crush logs --follow` for live tracing.

## 8. Local Models
- Register local OpenAI-compatible endpoints in `providers` and hot-swap between them.

## 9. Prompt Shortcuts
- Slash commands (`/view`, `/edit`, `/grep`) chain retrieval and editing within the chat.

## 10. Configuration Layers
- Settings load from `.crush.json` → `crush.json` → `$HOME/.config/crush/crush.json`.
- Keep project-specific roles/models locally; manage global defaults in the home config.

## 11. Provider Updates & Air-Gapped Mode
- Disable auto updates with `CRUSH_DISABLE_PROVIDER_AUTO_UPDATE=1` or config options.
- Manually refresh via `crush update-providers <path>` when offline.

## 12. Metrics & Telemetry
- Toggle metrics with `CRUSH_DISABLE_METRICS=1` or `options.disable_metrics`.
- Reuse logs for custom telemetry pipelines (e.g., Grafana dashboards).

## 13. Debug Flags
- `--debug`, `--debug_lsp`, and `--trace` expose provider, LSP, and internal traces.

## 14. Human-in-the-Loop Techniques
- Review edits with `/view` and `/diff` before approving.
- Tag prompts with roles (`[ARCH]`, `[ENGINEER]`, `[TESTER]`) and use named sessions per role.
- Request self-loops for iterative critique cycles.

## 15. Hidden Gems
- `.crushignore` trims noise; attribution flags manage commit metadata.
- Combine `context_paths` with `grep` for high-signal retrieval.
- MCP over SSE streams external events (tests, CI, telemetry) into Crush.

## TL;DR
- Isolate work with named sessions, curate context, swap providers as needed, wire up LSP/MCP tooling, automate safely, and watch logs/metrics for observability.
