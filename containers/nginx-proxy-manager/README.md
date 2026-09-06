# nginx-proxy-manager — live route table

Snapshot of NPM's actual configuration (pulled via its API, not hand-maintained —
re-pull if this drifts). This is the source of truth for what the future k8s
`Ingress`/`IngressRoute` + `cert-manager` setup (`docs/adr/0004-kubernetes-migration.md`)
needs to reproduce, one stack at a time, as each stack migrates.

Last pulled: 2026-09-06.

## Proxy hosts

| Domain | Forwards to | TLS | Force SSL | Access control | Notes |
|---|---|---|---|---|---|
| `api.yggdrasil.cfd` | `http://api:3000` | ✅ | ✅ | — | websocket, http2, hsts |
| `app.yggdrasil.cfd` | `http://web:3000` | ✅ | ✅ | — | websocket, http2, hsts |
| `atuin.smugiwara.com` | `http://atuin_server:8888` | ✅ | — | — | |
| `chat.smugiwara.com` | `http://webui:8080` | ✅ | ✅ | — | websocket, http2 |
| `cloud.smugiwara.com` | `http://nextcloud:80` | ✅ | ✅ | — | `client_max_body_size 0;` (large upload support), http2 |
| `docs.yggdrasil.cfd` | `http://docusaurus:3000` | ✅ | ✅ | — | http2, hsts |
| `flaresolverr.smugiwara.com` | `http://gluetun:8191` | ✅ | ✅ | — | (gluetun network namespace — see arr `CONTEXT.md`) |
| `hermes-dashboard.smugiwara.com` | `http://hermes_gateway:9119` | ✅ | — | — | websocket |
| `hermes.smugiwara.com` | `http://hermes_gateway:8642` | ✅ | — | **bearer token** (nginx `if` snippet, token stored in NPM only — see `.setup`/secrets vault, not this file) | websocket |
| `homearr.smugiwara.com` | `http://gluetun:7575` | ✅ | ✅ | — | (gluetun network namespace) |
| `immich.smugiwara.com` | `http://immich_server:2283` | ✅ | ✅ | — | `client_max_body_size 0;`, websocket, http2 |
| `infer.smugiwara.com` | `http://ollama:11434` | ✅ | — | **bearer token** (nginx `if` snippet, token stored in NPM only) | websocket, `proxy_read_timeout 600s;`, `proxy_buffering off;` (long-running inference streams) |
| `jellyfin.smugiwara.com` | `http://jellyfin:8096` | ✅ | ✅ | — | websocket, http2 |
| `netbird.smugiwara.com` | `http://netbird-dashboard:80` | ✅ | ✅ | — | custom `location` blocks for gRPC (`signalexchange.SignalExchange`, `management.ManagementService`) and WebSocket (`/relay`, `/ws-proxy/`) routes to `netbird-server:80` — see full snippet in NPM UI (Advanced tab) or `containers/netbird/CONTEXT.md`. http2, hsts |
| `npm.smugiwara.com` | `http://localhost:81` | ✅ | ✅ | — | NPM's own admin UI |
| `openclaw.smugiwara.com` | `http://openclaw_gateway:18789` | ✅ | — | — | websocket |
| `portainer.smugiwara.com` | `http://portainer:9000` | ✅ | ✅ | — | websocket, http2 |
| `prowlarr.smugiwara.com` | `http://gluetun:9696` | ✅ | ✅ | — | (gluetun network namespace) |
| `qbittorrent.smugiwara.com` | `http://gluetun:8080` | ✅ | ✅ | — | (gluetun network namespace) |
| `radarr.smugiwara.com` | `http://gluetun:7878` | ✅ | ✅ | — | (gluetun network namespace) |
| `seerr.smugiwara.com` | `http://seerr:5055` | ✅ | ✅ | — | websocket |
| `sonarr.smugiwara.com` | `http://gluetun:8989` | ✅ | ✅ | — | (gluetun network namespace) |
| `websearch.smugiwara.com` | `http://searxng:8080` | ✅ | — | **Access List** `Mugiwara Only` (HTTP Basic Auth, user `mugiwara`) | websocket |
| `yggdrasil.cfd` | `http://landing:3000` | ✅ | ✅ | — | http2, hsts |

All 24 proxy hosts are enabled. No redirection hosts or TCP/UDP streams configured.

## Access lists

- **`Mugiwara Only`** (id 1) — HTTP Basic Auth, single user `mugiwara`. Only attached to `websearch.smugiwara.com`. Password hash lives in NPM's own SQLite DB, not in this repo.

## Certificates

24 Let's Encrypt certificates, one per proxy host (HTTP-01, auto-renewed by NPM). No wildcard cert — see `CONTEXT.md`'s "Automatic SSL" note for why.

## Bearer-token-gated hosts

`hermes.smugiwara.com` and `infer.smugiwara.com` use a raw nginx `if ($http_authorization != "Bearer <token>") { return 401; }` snippet in NPM's Advanced tab instead of an Access List, because these are API endpoints (not browsable UIs) — same reasoning as `searxng`'s Access List choice, inverted. **Token values are intentionally not reproduced here** — they live only in NPM's config and whatever client configs reference them (see `containers/hermes/CONTEXT.md`, `containers/ollama/CONTEXT.md`). When these routes migrate to k8s, the equivalent is a Traefik `BasicAuth`/`ForwardAuth` middleware or an `Authorization` header check, with the token in a k8s `Secret`, not committed here either.

## k8s migration mapping (for later)

Per stack, once its Helm chart replaces the Compose service (`docs/adr/0004-kubernetes-migration.md`):
- Plain `force_ssl` host → plain `Ingress` + `cert-manager.io/cluster-issuer` annotation (already the default shape in `helm/homelab-common`'s `_ingress.tpl`).
- `websocket`-enabled hosts → no special Traefik config needed (WebSocket upgrade works out of the box on `Ingress`/`IngressRoute`), unlike NPM which needs the checkbox.
- Bearer-token hosts (`hermes`, `infer`) → Traefik `ForwardAuth` or `headers` middleware, token from a `Secret`.
- `websearch` (Basic Auth Access List) → Traefik `BasicAuth` middleware backed by a `Secret` (htpasswd-format).
- `netbird`'s custom gRPC/WebSocket `location` blocks → likely an `IngressRoute` (Traefik CRD) with per-path rules, or a dedicated gRPC-aware middleware — this one needs the most care, migrate last.
- `gluetun`-namespaced hosts (arr stack: flaresolverr/homearr/prowlarr/qbittorrent/radarr/sonarr) → only make sense once `arr`'s VPN-sidecar networking has a k8s equivalent (shared pod network namespace); these all migrate together, last.
