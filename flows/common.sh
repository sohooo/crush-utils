#!/usr/bin/env bash

# Shared helpers for GitLab-driven Crush flows.

GITLAB_AUTH_HEADER=()

error() {
  echo "Fehler: $*" >&2
}

require_commands() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Die folgenden erforderlichen Befehle fehlen: ${missing[*]}"
    exit 1
  fi
}

require_env_vars() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Die folgenden Umgebungsvariablen müssen gesetzt sein: ${missing[*]}"
    exit 1
  fi
}

load_repo_env() {
  local repo_dir="$1"
  if [[ -f "$repo_dir/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$repo_dir/.env"
    set +a
  fi
}

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

init_gitlab_api() {
  local base_url="${1:-${GITLAB_BASE_URL:-https://gitlab.com}}"

  require_env_vars GITLAB_TOKEN

  GITLAB_BASE_URL_RESOLVED="$base_url"
  GITLAB_API_BASE="$GITLAB_BASE_URL_RESOLVED/api/v4"
  GITLAB_AUTH_HEADER=(-H "PRIVATE-TOKEN: $GITLAB_TOKEN")
}

_gitlab_require_initialized() {
  if [[ -z "${GITLAB_API_BASE:-}" || ${#GITLAB_AUTH_HEADER[@]} -eq 0 ]]; then
    error "Die GitLab-API-Hilfsfunktionen wurden nicht initialisiert (rufe init_gitlab_api auf)."
    exit 1
  fi
}

gitlab_api_get() {
  _gitlab_require_initialized
  local endpoint="$1"
  shift || true
  local url="$GITLAB_API_BASE$endpoint"
  if [[ $# -gt 0 ]]; then
    local IFS='&'
    url+="?$(printf '%s' "$*")"
  fi
  curl -fsSL "${GITLAB_AUTH_HEADER[@]}" "$url"
}

gitlab_raw_get() {
  _gitlab_require_initialized
  local url="$1"
  curl -fsSL "${GITLAB_AUTH_HEADER[@]}" "$url"
}
