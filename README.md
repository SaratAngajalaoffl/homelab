# homelab

Self-hosted Docker stacks for an Arch Linux desktop. Compose files and env templates live in this repo; runtime data and secrets stay on the host.

## Prerequisites

- Docker with Compose v2 (`docker compose`)
- Storage directories (create once):

```bash
mkdir -p ~/storage/homelab/homelab-conf ~/storage/homelab/homelab-data
```

## Quick start

```bash
git clone <repo-url> ~/homelab
cd ~/homelab/containers

# Bootstrap env for a stack (repeat per stack as needed)
cp arr/arr.example arr/arr.env
# Edit arr/arr.env — see arr/.setup for WireGuard keys and other secrets

# Start one stack or everything
./up-all-stacks.sh arr
./up-all-stacks.sh          # all stacks

# Stop
./down-all-stacks.sh arr
./down-all-stacks.sh        # all stacks
```

`*.env` files are gitignored. Never commit secrets.

## Environment: export and restore

Secret values live in `*.env` files under `containers/`. Committed `*.example` files hold the same keys with placeholders.

### Export — `scripts/env/copy_env.sh`

Walks the repo (or a directory you pass as the first argument), finds every `*.env`, merges assignments into one flat JSON object (later files override duplicate keys), and copies that JSON to the clipboard.

Store the JSON in a secrets vault (e.g. Bitwarden note) for restore on a new machine.

```bash
./scripts/env/copy_env.sh
# optional: ./scripts/env/copy_env.sh containers/arr
```

### Restore — `scripts/env/apply_env.sh`

Reads flat JSON from stdin, or from the clipboard if stdin is empty. Finds every `*.example` under the search root and writes a sibling `.env` (e.g. `arr.example` → `arr.env`), filling keys that exist in the JSON.

```bash
./scripts/env/apply_env.sh </path/to/export.json
# or paste JSON into the clipboard, then:
./scripts/env/apply_env.sh
```

Optional first argument: search root directory (defaults to the git repo root).

## Stacks

| Stack | Directory | Description |
|-------|-----------|-------------|
| arr | `containers/arr/` | *arr suite + qBittorrent + FlareSolverr behind Gluetun VPN |
| immich | `containers/immich/` | Photo backup (Immich + Postgres + Redis) |
| jellyfin | `containers/jellyfin/` | Media server + Seerr request manager |
| monitoring | `containers/monitoring/` | Prometheus, Grafana, Loki, Promtail, cAdvisor, node-exporter |
| netbird | `containers/netbird/` | Self-hosted NetBird mesh VPN (dashboard, signal, relay, management, routing peer) |
| nextcloud | `containers/nextcloud/` | File sync and collaboration |
| portainer | `containers/portainer/` | Docker management UI |
| webui | `containers/webui/` | Open WebUI (connects to Ollama on the host) |

## Storage layout

| Path | Purpose |
|------|---------|
| `~/homelab/` | This repo — compose files, config templates, scripts |
| `~/storage/homelab/homelab-conf/` | App config and state (Grafana DB, *arr configs, etc.) |
| `~/storage/homelab/homelab-data/` | User content (torrents, media, photos, Nextcloud files) |

## Agent docs

AI-oriented documentation lives alongside the repo:

- [`CONTEXT.md`](CONTEXT.md) — domain glossary
- [`CLAUDE.md`](CLAUDE.md) — conventions and commands for agents
- [`docs/adr/`](docs/adr/) — architecture decision records
