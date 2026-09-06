# ADR 0003: Per-stack Docker Compose directories

## Status
Superseded by [ADR 0004](0004-kubernetes-migration.md) — the per-stack isolation principle carries over (one Helm chart per stack, one namespace each), but `containers/` and the Compose orchestration scripts described below have been removed from the repo now that every stack runs on k3s.

## Context
The homelab runs eight independent service groups (arr, immich, jellyfin, monitoring, netbird, nextcloud, portainer, webui) with different dependencies, env files, and restart policies. A single monolithic `docker-compose.yml` would couple unrelated stacks and make partial updates risky.

## Decision
Each service group is a **stack**: a subdirectory of `containers/` containing its own `docker-compose.yml`, env template(s), and optional `.setup` / `CONTEXT.md`.

Orchestration is handled by two scripts at `containers/`:

- `up-all-stacks.sh [STACK]` — `docker compose up -d --pull always --build` for one or all stacks.
- `down-all-stacks.sh [STACK]` — `docker compose down` for one or all stacks.

Stacks are discovered by globbing `containers/*/docker-compose.yml`.

## Alternatives considered
- **Single compose file with profiles** — reduces file count but couples lifecycle; bringing down monitoring would require care not to affect arr.
- **docker compose -f with extends** — shared fragments add indirection without clear benefit at this scale.
- **Portainer-only management** — no version-controlled compose in git; harder for agents and code review.

## Consequences
- Adding a stack means creating `containers/<name>/` with a compose file; scripts pick it up automatically.
- Cross-stack networking is not implicit; services communicate via host ports or explicit Docker networks if added later.
- Nginx Proxy Manager (planned) will likely be its own stack directory following the same pattern.
