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
