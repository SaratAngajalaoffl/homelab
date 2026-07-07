# netbird Stack Context

## Glossary

**netbird-stack** — compose project `netbird-stack` in `containers/netbird/`. Self-hosted NetBird control plane plus a routing peer on the homelab host.

**Dashboard** — `netbirdio/dashboard` UI. Binds `127.0.0.1:31932:80`. Configured via `dashboard.env` (API endpoints, OIDC). Uses embedded IdP (`USE_AUTH0=false`).

**Signal** — `netbirdio/signal` WebRTC signaling server. Binds localhost ports `38083` (HTTP) and `31100` (gRPC). Referenced in `management.json` as `netbird.yggdrasil.cfd:443` (expects external TLS termination).

**Relay** — `netbirdio/relay` TURN/relay server. HTTP on `127.0.0.1:38084`; STUN on `3478/udp` (host-wide, well-known port). Configured via `relay.env` (`NB_AUTH_SECRET`, `NB_EXPOSED_ADDRESS`).

**Management** — `netbirdio/management` API and datastore. Binds `127.0.0.1:31801:80`. Mounts `management.json` (committed config for Stuns, Relay, Signal URIs, embedded IdP) and persistent data at `homelab-conf/netbird/management`.

**Routing peer** — `netbirdio/netbird` client container with `CAP_NET_ADMIN`. Joins the mesh using `NB_SETUP_KEY` from `routing.env`. Persistent client state at `homelab-conf/netbird/client`.

**management.json** — committed NetBird management server config. Defines STUN URI, relay addresses, signal URI, embedded IdP issuer, and encryption keys. Must stay consistent with `dashboard.env` / `relay.env` endpoint hostnames.

**Embedded IdP** — NetBird's built-in identity provider (`EmbeddedIdP.Enabled: true` in management.json). Dashboard OIDC client uses `AUTH_AUTHORITY=https://netbird.yggdrasil.cfd/oauth2`.

**External TLS** — public endpoints use `netbird.yggdrasil.cfd` (HTTPS on 443). Internal compose services listen on localhost; something upstream (firewall, reverse proxy, or planned NPM) must terminate TLS and route to them.

**Env files** — `dashboard.env`, `relay.env`, `routing.env` (each has a `*.example` template). All gitignored when copied to `*.env`.

**Localhost binding** — dashboard, signal, relay HTTP, and management bind to `127.0.0.1` only. Only STUN `3478/udp` is exposed on all interfaces.
