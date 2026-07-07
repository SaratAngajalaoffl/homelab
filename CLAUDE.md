# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Detached homelab repo at `~/homelab` for self-hosted Docker infrastructure on an Arch Linux desktop. It is separate from `~/dotfiles-arch` (desktop dotfiles) and replaces the legacy `containers/` directory that lived in the flat `~/dotfiles` repo.

The repo owns compose files, env templates (`*.example`), monitoring provisioning, and stack lifecycle scripts. It does **not** own runtime data (`~/storage/homelab/`) or secrets (`*.env`).

## Key commands

```bash
# Start all stacks (or one stack by name)
cd ~/homelab/containers
./up-all-stacks.sh
./up-all-stacks.sh monitoring

# Stop all stacks (or one)
./down-all-stacks.sh
./down-all-stacks.sh arr

# Bring up a single stack manually
docker compose -f ~/homelab/containers/arr/docker-compose.yml up -d --pull always --build
```

## Rules for agents

- **Never read, write, or commit `*.env` files.** They are gitignored and contain secrets.
- **May update `*.example` files** when adding new required env vars. Keep placeholders empty or clearly marked.
- **May create or update `.setup` files** for manual bootstrap instructions (see arr and netbird).
- **Follow the storage convention:** config/state → `${HOME}/storage/homelab/homelab-conf/<service>/`; user content → `${HOME}/storage/homelab/homelab-data/<service>/`.
- **One stack per directory** under `containers/`. Do not merge unrelated services into a single compose file.
- **Prefer `user: "1000:1000"`** on LinuxServer.io and similar images when bind-mounting under `$HOME`. Some images define their own users (Nextcloud `www-data`, Immich postgres) — read compose comments before overriding.
- **Do not rigidly apply a port formula.** Host ports are ad-hoc `31xxx` mappings today. Document new ports in compose comments. Nginx Proxy Manager is planned next to front services by hostname.

## Architecture

### Directory layout

```
~/homelab/
├── README.md              # Human quick start
├── CONTEXT.md             # Domain glossary (this file's companion)
├── CLAUDE.md              # Agent playbook (this file)
├── docs/adr/              # Architecture decision records
└── containers/
    ├── up-all-stacks.sh
    ├── down-all-stacks.sh
    ├── arr/               # Has CONTEXT.md + .setup
    ├── netbird/           # Has CONTEXT.md + .setup
    ├── immich/
    ├── jellyfin/
    ├── monitoring/
    ├── nextcloud/
    ├── portainer/
    └── webui/
```

### Storage

| Tree | Holds | Example |
|------|-------|---------|
| `homelab-conf/` | Config, DBs, app state | `.../sonarr/config`, `.../monitoring/grafana` |
| `homelab-data/` | Bulk user content | `.../arr/torrents`, `.../immich/server-data` |

### Secrets bootstrap

1. `cp <stack>.example <stack>.env` in the stack directory.
2. Fill in values on the host.
3. Read `<stack>/.setup` if present for non-obvious steps.

### Stacks overview

| Stack | Notes |
|-------|-------|
| `arr` | Gluetun VPN sidecar; torrent apps share its network namespace. See `containers/arr/CONTEXT.md`. |
| `netbird` | Self-hosted control plane; internal ports on localhost. See `containers/netbird/CONTEXT.md`. |
| `monitoring` | Grafana provisioning in-repo; persistent data under homelab-conf. |
| `jellyfin` | Reads media from `homelab-data/arr/media`; Seerr for requests. |
| `immich` | Pinned image versions; postgres + redis + ML container. |
| `nextcloud` | Bind mounts need `www-data` ownership — see compose header comment. |
| `portainer` | Docker socket mount for container management. |
| `webui` | Open WebUI; `OLLAMA_BASE_URL` points to host Ollama via `host.docker.internal`. |

### Planned

**Nginx Proxy Manager** — reverse proxy stack to be added. Will terminate TLS and route by hostname, reducing reliance on per-service host port mappings.

## ADRs

- **ADR 0001** (`docs/adr/0001-detached-homelab-repo.md`): Why homelab is a separate repo from dotfiles.
- **ADR 0002** (`docs/adr/0002-storage-layout.md`): Why homelab-conf and homelab-data are split.
- **ADR 0003** (`docs/adr/0003-per-stack-compose.md`): Why each service group is its own compose stack.
