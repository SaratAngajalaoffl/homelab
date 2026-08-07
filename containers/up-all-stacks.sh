#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf 'Usage: %s [STACK]\n' "$(basename "$0")" >&2
  printf '  With no arguments: bring up every directory under %s that has a docker-compose.yml.\n' "$ROOT_DIR" >&2
  printf '  With STACK: bring up only that subdirectory (e.g. monitoring, arr, jellyfin).\n' >&2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Shared external network: nginx-proxy-manager and every HTTP-facing stack
# join this to reach each other by container name. Stacks reference it as
# `external: true`, so it must exist before any of them start.
if ! docker network inspect edge >/dev/null 2>&1; then
  echo "==> Creating shared docker network: edge"
  docker network create edge
fi

run_stack() {
  local stack_dir="$1"
  local compose_file="$stack_dir/docker-compose.yml"
  local stack_name
  stack_name="$(basename "$stack_dir")"
  if [[ ! -f "$compose_file" ]]; then
    printf 'Error: no docker-compose.yml in %s\n' "$stack_dir" >&2
    exit 1
  fi
  echo "==> Bringing up stack: $stack_name"
  docker compose -f "$compose_file" up -d --pull always --build
}

if [[ -n "${1:-}" ]]; then
  requested="$(printf '%s' "$1" | sed 's|/+$||')"
  stack_dir="$ROOT_DIR/$requested"
  if [[ ! -d "$stack_dir" ]]; then
    printf 'Error: unknown stack %q (no directory %s)\n' "$1" "$stack_dir" >&2
    usage
    exit 1
  fi
  run_stack "$stack_dir"
  echo "Stack $(basename "$stack_dir") has been started."
else
  for compose_file in "$ROOT_DIR"/*/docker-compose.yml; do
    [ -e "$compose_file" ] || continue
    run_stack "$(dirname "$compose_file")"
  done
  echo "All stacks have been started (where compose files exist)."
fi
