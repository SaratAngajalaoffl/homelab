# Homelab Context

## Glossary

**Stack** — a self-contained Docker Compose project in `containers/<name>/`, with its own `docker-compose.yml`, env template, and optional `.setup` instructions. Examples: `arr`, `immich`.

**Compose file** — the `docker-compose.yml` inside a stack directory. Each stack is brought up independently via `docker compose -f <stack>/docker-compose.yml`.

**Env template** — a committed `*.example` file listing required environment variables with empty or placeholder values. Copied to a gitignored `*.env` on the host before first run.

**Setup manifest** — an optional `.setup` file in a stack directory with plain-text instructions for secrets or manual bootstrap steps that cannot be committed (e.g. VPN keys, API tokens). Read after copying the env template.

**Env export** — `scripts/env/copy_env.sh`. Discovers all `*.env` files under the repo (or a given search root), merges key/value assignments into one flat JSON object (later files win on duplicate keys), and copies the JSON to the system clipboard. Used to back up secrets to a vault.

**Env restore** — `scripts/env/apply_env.sh`. Reads flat JSON from stdin or the clipboard, finds every `*.example` file under the search root, and writes a sibling `*.env` by filling keys present in the JSON. Preserves comments and key order from the example template.

**Flat env JSON** — a single JSON object `{ "KEY": "value", ... }` with no nesting. The export/restore scripts use this format so all stack secrets can live in one vault note.

**homelab-conf** — host path `${HOME}/storage/homelab/homelab-conf/`. Holds app configuration, databases, and small persistent state. Bind-mounted into containers. Never committed to git.

**homelab-data** — host path `${HOME}/storage/homelab/homelab-data/`. Holds bulk user-generated content (torrents, media libraries, photo libraries, Nextcloud files). Bind-mounted into containers. Never committed to git.

**Orchestration scripts** — `containers/up-all-stacks.sh` and `containers/down-all-stacks.sh`. Iterate over every `containers/*/docker-compose.yml` or target a single stack by name.

**Gluetun** — VPN sidecar container in the arr stack. Provides a shared network namespace (`network_mode: "service:gluetun"`) so torrent-related apps route through ProtonVPN WireGuard. Exposes all arr-stack host ports on the gluetun container.

**VPN-routed service** — a container using `network_mode: "service:gluetun"` so its traffic exits through the VPN tunnel. Includes qBittorrent, Sonarr, Radarr, Prowlarr, FlareSolverr, and Homarr in the arr stack.

**dockerproxy** — a read-only Docker socket proxy (`tecnativa/docker-socket-proxy`) on host networking. Used by Homarr to inspect containers without mounting the raw socket into the VPN namespace.

**PUID/PGID** — LinuxServer.io images in the arr stack run as `1000:1000` to match a typical desktop user's ownership on bind mounts under `$HOME`.

**Host port** — the left side of a `ports:` mapping in compose. Reserved for things nginx-proxy-manager can't front: UDP protocols, VPN-tunnel utility ports, and LAN-only debug access. Everything else reaches nginx-proxy-manager over the `edge` network instead.

**Nginx Proxy Manager** — `containers/nginx-proxy-manager/`. Sole public listener on the host (`:80`/`:443`); terminates TLS with automatic per-host Let's Encrypt certs and routes to backends by container name over the external `edge` docker network. See its `CONTEXT.md` + `.setup`.

**`edge` network** — external docker bridge network joined by nginx-proxy-manager and every HTTP-facing container across every stack. Auto-created by `up-all-stacks.sh` if missing.

**netbird** — `containers/netbird/`. Self-hosted mesh VPN control plane (`netbird-server` + `dashboard`), trimmed to just those two containers — no routing peer, no external IdP, no coturn. Purpose is narrow: let an enrolled laptop reach this host's SSH port over an encrypted overlay network without ever exposing `22/tcp` to the internet. The host itself joins the mesh via a native systemd `netbird` client, not a container. See its `CONTEXT.md` + `.setup`.

