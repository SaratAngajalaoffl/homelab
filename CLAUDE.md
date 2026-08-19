# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Detached homelab repo at `~/homelab` for self-hosted Docker infrastructure on an Arch Linux desktop. It is separate from `~/dotfiles-arch` (desktop dotfiles) and replaces the legacy `containers/` directory that lived in the flat `~/dotfiles` repo.

The repo owns compose files, env templates (`*.example`), and stack lifecycle scripts. It does **not** own runtime data (`~/storage/homelab/`) or secrets (`*.env`).

## Key commands

```bash
# Start all stacks (or one stack by name)
cd ~/homelab/containers
./up-all-stacks.sh
./up-all-stacks.sh arr

# Stop all stacks (or one)
./down-all-stacks.sh
./down-all-stacks.sh arr

# Bring up a single stack manually
docker compose -f ~/homelab/containers/arr/docker-compose.yml up -d --pull always --build

# Export all *.env values to clipboard as flat JSON (human secrets workflow)
./scripts/env/copy_env.sh

# Restore *.env files from JSON (stdin or clipboard)
./scripts/env/apply_env.sh
```

## Rules for agents

- **Never read, write, or commit `*.env` files** during normal agent work. They are gitignored and contain secrets. Exception: only run `scripts/env/copy_env.sh` or `scripts/env/apply_env.sh` when the user explicitly asks for secrets export/restore.
- **May update `*.example` files** when adding new required env vars. Keep placeholders empty or clearly marked.
- **May create or update `.setup` files** for manual bootstrap instructions (see arr).
- **Follow the storage convention:** config/state → `${HOME}/storage/homelab/homelab-conf/<service>/`; user content → `${HOME}/storage/homelab/homelab-data/<service>/`.
- **One stack per directory** under `containers/`. Do not merge unrelated services into a single compose file.
- **Prefer `user: "1000:1000"`** on LinuxServer.io and similar images when bind-mounting under `$HOME`. Some images define their own users (Nextcloud `www-data`, Immich postgres) — read compose comments before overriding.
- **No host port publishing for HTTP services.** `nginx-proxy-manager` is the only public listener (`:80`/`:443`) — host nginx has been retired. Every HTTP-facing container joins the external `edge` docker network (see `up-all-stacks.sh`, which creates it if missing) and NPM reaches it by container name and container-internal port; do not add a `ports:` entry for a service's web UI. `31xxx` host ports only remain for things that genuinely can't go through nginx: UDP protocols (jellyfin autodiscovery) and VPN-tunnel utility ports (gluetun's HTTP proxy/Shadowsocks/torrent-inbound). Document any new one of those in compose comments. See `containers/nginx-proxy-manager/CONTEXT.md` + `.setup`.

## Architecture

### Directory layout

```
~/homelab/
├── README.md              # Human quick start
├── CONTEXT.md             # Domain glossary (this file's companion)
├── CLAUDE.md              # Agent playbook (this file)
├── docs/adr/              # Architecture decision records
├── scripts/
│   └── env/               # copy_env.sh, apply_env.sh — secrets round-trip
└── containers/
    ├── up-all-stacks.sh
    ├── down-all-stacks.sh
    ├── arr/               # Has CONTEXT.md + .setup
    ├── immich/
    ├── jellyfin/
    ├── netbird/           # Has CONTEXT.md + .setup
    ├── nextcloud/
    ├── portainer/
    └── webui/
```

### Storage

| Tree | Holds | Example |
|------|-------|---------|
| `homelab-conf/` | Config, DBs, app state | `.../sonarr/config`, `.../nextcloud/app` |
| `homelab-data/` | Bulk user content | `.../arr/torrents`, `.../immich/server-data` |

### Secrets bootstrap

1. `cp <stack>.example <stack>.env` in the stack directory.
2. Fill in values on the host.
3. Read `<stack>/.setup` if present for non-obvious steps.

For machine migration or disaster recovery, the human operator uses `scripts/env/copy_env.sh` (export all `*.env` to flat JSON via clipboard) and `scripts/env/apply_env.sh` (restore from JSON into paired `.env` files). Store exported JSON in a vault (e.g. Bitwarden), not in git.

### Stacks overview

| Stack | Notes |
|-------|-------|
| `arr` | Gluetun VPN sidecar; torrent apps share its network namespace. See `containers/arr/CONTEXT.md`. |
| `atuin` | Self-hosted Atuin shell history sync server + Postgres, so history merges between the desktop and a MacBook. E2E encrypted client-side. See `containers/atuin/CONTEXT.md` + `.setup`. |
| `jellyfin` | Reads media from `homelab-data/arr/media`; Seerr for requests. |
| `immich` | Pinned image versions; postgres + redis + ML container. |
| `netbird` | Trimmed self-hosted VPN control plane (`netbird-server` + `dashboard` only) so a laptop can reach this host's SSH port without exposing it to the internet. See `containers/netbird/CONTEXT.md` + `.setup`. |
| `nextcloud` | Bind mounts need `www-data` ownership — see compose header comment. |
| `ollama` | Dockerized Ollama server with GPU passthrough (CDI, not `deploy.reservations.devices` — see CONTEXT.md). No auth of its own; the public NPM proxy host enforces an API key via an Advanced-tab nginx snippet. Replaces the old host-native `ollama.service`. See `containers/ollama/CONTEXT.md` + `.setup`. |
| `openclaw` | Self-hosted [OpenClaw](https://openclaw.ai) personal AI assistant/agent gateway (email, calendar, chat-app channels). Higher blast radius than most stacks — its gateway token grants agent control. See `containers/openclaw/CONTEXT.md` + `.setup`. |
| `portainer` | Docker socket mount for container management. |
| `webui` | Open WebUI; `OLLAMA_BASE_URL` points to the `ollama` stack container over the `edge` network. |
| `nginx-proxy-manager` | GUI reverse proxy; sole public listener on `:80`/`:443`, terminates TLS with automatic per-host Let's Encrypt (HTTP-01) certs. Routes to backends by container name over the external `edge` network — no host nginx, no `host.docker.internal` hop. See `containers/nginx-proxy-manager/CONTEXT.md` + `.setup`. |

## ADRs

- **ADR 0001** (`docs/adr/0001-detached-homelab-repo.md`): Why homelab is a separate repo from dotfiles.
- **ADR 0002** (`docs/adr/0002-storage-layout.md`): Why homelab-conf and homelab-data are split.
- **ADR 0003** (`docs/adr/0003-per-stack-compose.md`): Why each service group is its own compose stack.
