# nginx-proxy-manager Stack Context

## Glossary

**nginx-proxy-manager-stack** — compose project `nginx-proxy-manager-stack` in `containers/nginx-proxy-manager/`. Single-container [jc21/nginx-proxy-manager](https://nginxproxymanager.com/) (NPM). It is now **the only public listener on this host** — host nginx has been retired. NPM binds `0.0.0.0:80` and `0.0.0.0:443` directly and terminates TLS itself.

**`edge` network** — external docker bridge network (`docker network create edge`, or auto-created by `up-all-stacks.sh`). NPM and every HTTP-facing container across every stack join it, and NPM reaches each backend by **container name and container-internal port** — no other stack publishes a host port for its web UI anymore. This replaced the previous two-layer model (host nginx → `127.0.0.1:31xxx` → container) entirely; there is no `host.docker.internal` hop left in the chain.

**What still publishes a host port, and why** — a handful of things aren't HTTP and can't be routed by any nginx, proxy manager or otherwise:
- `arr`'s gluetun VPN-tunnel utility ports (HTTP proxy `31888`, Shadowsocks `31838`) and qBittorrent's inbound torrent port (`31681`)
- `jellyfin`'s LAN autodiscovery broadcast (`31759/udp`)

Everything else lost its `ports:` entry and gained `edge` in its `networks:` list.

**Automatic SSL** — per-proxy-host Let's Encrypt certificates via HTTP-01, requested and renewed by NPM itself through its GUI ("Request a new SSL Certificate" on each proxy host). No DNS provider API credentials involved — deliberately chosen over a wildcard DNS-01 cert to avoid handing NPM DNS-zone-edit credentials, and because HTTP-01 needed no new host-level dependency. This replaces the old host-side `certbot` setup, which was `authenticator = manual` (a human pasting a TXT record every renewal) — that timer (`certbot-renew.timer`) and the old wildcard cert should be disabled/retired once NPM's per-host certs are live (see `.setup`).

**Multi-container stacks sharing one network namespace (`arr`)** — Sonarr/Radarr/Prowlarr/HomeArr/qBittorrent/FlareSolverr all run `network_mode: "service:gluetun"`, so they have no network identity of their own; gluetun's is the only one that exists. `gluetun` joins `edge`, and NPM's proxy hosts for those apps target `gluetun:<app's container port>` (e.g. `gluetun:8989` for Sonarr), not the app's own container name.

**`portainer.loki.lan` carve-out** — a second, non-`smugiwara.com` hostname for LAN-only access to Portainer. Let's Encrypt HTTP-01 cannot issue a cert for a `.lan` name (not publicly resolvable), so it can't get an automatic NPM cert the way the `*.smugiwara.com` hosts do. It already didn't have a properly matching cert before this migration (host nginx reused the `smugiwara.com` wildcard cert for it, a hostname mismatch). See `.setup` for options.

**Containers outside this repo** — `pdf-edit.smugiwara.com` (port 11901) and `pm-analysis.smugiwara.com` (port 11909) aren't defined by any compose file under `containers/`. Whatever manages them needs to join the `edge` network on its own (`docker network connect edge <container>`, or add `edge` to its own compose) before NPM can reach them by name.

**Data** — SQLite DB, proxy host config, and NPM's own Let's Encrypt cert store live at `homelab-conf/nginx-proxy-manager/{data,letsencrypt}`.

**Admin UI** — bound to `127.0.0.1:31881:81`, not public. Reach it via SSH tunnel, or front it with its own NPM proxy host (`npm.smugiwara.com` → `nginx-proxy-manager:81`) once bootstrapped and drop the host binding.
