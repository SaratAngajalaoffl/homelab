# arr Stack Context

## Glossary

**arr-stack** — compose project `arr-stack` in `containers/arr/`. Groups torrent and media-automation apps behind a VPN.

**Gluetun** — `qmcgaw/gluetun` container with `NET_ADMIN` and `/dev/net/tun`. Terminates ProtonVPN WireGuard from `arr.env`. All VPN-routed services share its network namespace. Host ports for every arr-stack UI are declared on gluetun.

**VPN-routed service** — container with `network_mode: "service:gluetun"` and `depends_on: gluetun: condition: service_healthy`. Traffic exits via VPN. Includes qbittorrent, flaresolverr, sonarr, radarr, prowlarr, homarr.

**dockerproxy** — `ghcr.io/tecnativa/docker-socket-proxy` on `network_mode: host`. Homarr reaches it at `tcp://172.17.0.1:2375` to list containers without a raw socket mount inside the VPN namespace (Homarr still mounts the socket directly for its own Docker integration).

**LinuxServer image** — qbittorrent, sonarr, radarr, prowlarr use `lscr.io/linuxserver/*` with `PUID=1000`, `PGID=1000`, config under `homelab-conf/<app>/config`, and shared media root `homelab-data/arr`.

**Shared media root** — `homelab-data/arr` mounted at `/data` in Sonarr and Radarr. Torrents land in `homelab-data/arr/torrents` (qBittorrent mount at `/data/torrents`).

**Homarr** — dashboard (`ghcr.io/homarr-labs/homarr`) inside the VPN namespace. Reads `SECRET_ENCRYPTION_KEY` from `arr.env` for credential encryption.

**FlareSolverr** — Cloudflare bypass proxy for indexers; runs inside VPN namespace. Image from `ghcr.io/flaresolverr/flaresolverr`.

**Host ports (current)** — mapped on gluetun for running services: Sonarr `31989`, Radarr `31978`, Prowlarr `31969`, Homarr `31757`, qBittorrent Web UI `41830`, qBittorrent peer `31681`, FlareSolverr `31819`. Gluetun also declares `31868` and `31677` (Lidarr/Bazarr defaults) but those services are not in this compose file yet. Ad-hoc numbering; NPM planned to replace manual forwarding.

**arr.env** — single env file for gluetun (VPN vars) and homarr (`SECRET_ENCRYPTION_KEY`). Template: `arr.example`.
