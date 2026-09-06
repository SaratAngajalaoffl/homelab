# openclaw Stack Context

## Glossary

**openclaw-stack** — compose project `openclaw-stack` in `containers/openclaw/`. Self-hosted OpenClaw personal AI assistant/agent gateway (email, calendar, chat channels).

**k8s migration** — `~/homelab/helm/openclaw/` holds this stack's Helm chart, converted per `docs/adr/0004-kubernetes-migration.md`. One Deployment (`server`) via `helm/homelab-common`, one **plain** `homelab-common.ingress` (`openclaw.smugiwara.com`) — **not** a bearer-token `IngressRoute` like ollama/hermes's API routes. Live production deployment as of 2026-09-06; Compose stack was already stopped before this migration. No `openclaw-cli` equivalent deployed (it was a one-off profile-gated Compose service, not a long-running one — run it as a one-off `kubectl run`/temp pod against the same PVCs when needed, same pattern used for the doctor-fix step below).

**Corrected an initial mistake: this needed a plain Ingress, not a bearer-token `IngressRoute`** — unlike ollama's and hermes's *API* endpoints (pure API, no browser use, correctly gated by a Traefik `HeaderRegexp` bearer check), OpenClaw multiplexes its **browser control UI and its API on the same port** (`18789`), same shape as hermes's *dashboard* route. NPM's original config confirms this: its README shows no auth column entry for `openclaw.smugiwara.com` (unlike the explicit "bearer token" shown for ollama/hermes-API) — access control was always the app's own login screen (paste `OPENCLAW_GATEWAY_TOKEN`), not an edge-level gate. The first version of this chart wrongly copied the ollama/hermes IngressRoute pattern, which blocks all plain browser navigation (no `Authorization` header on page load) — caught when the user reported a 404 opening the site in a browser. Fixed by switching to a plain Ingress and removing the bearer-token IngressRoute/Certificate/`values.secret.yaml` entirely.

**Traefik proxy-trust fix, needed after switching to a plain Ingress** — once requests reached the app, it 403'd every request with `proxy_attribution_required` (`"observed unattributable proxy-shaped traffic from <traefik-pod-ip>"`). Same root cause category as netbird's `trustedHTTPProxies` fix: the app defends against a proxy spoofing `X-Forwarded-For`, and needs Traefik's pod IP allowlisted. Fixed via the app's own CLI (writes directly into the migrated `openclaw.json`, so it's now part of that PVC's persisted state, not something the Helm chart manages):
```
kubectl exec -n homelab-openclaw <pod> -- node dist/index.js config set gateway.trustedProxies '["10.42.0.0/16"]'
kubectl exec -n homelab-openclaw <pod> -- node dist/index.js config set gateway.allowRealIpFallback true
```
Setting `trustedProxies` alone wasn't sufficient — `allowRealIpFallback` was also required (OpenClaw's proxy-attribution logic apparently needs the `x-real-ip` fallback path even with the CIDR trusted, at least with Traefik's default forwarded-header behavior). Both together resolved it; restart the gateway pod after either change to pick it up.

**Control UI WebSocket origin also needed updating** — after the Ingress/proxy-trust fixes, the page itself loaded but the browser's WebSocket connection was rejected ("Browser origin not allowed"): `gateway.controlUi.allowedOrigins` still held the pre-migration `https://openclaw.yggdrasil.cfd` value (from before the repo-wide `yggdrasil.cfd` → `smugiwara.com` domain migration, commit `4ba528d`) rather than `https://openclaw.smugiwara.com`. Fixed the same way, via the app's own CLI:
```
kubectl exec -n homelab-openclaw <pod> -- node dist/index.js config set gateway.controlUi.allowedOrigins '["https://openclaw.smugiwara.com"]'
```
This one applies live, no gateway restart needed (per the CLI's own confirmation message) — though the pod was recycled anyway as part of testing.

**Three separate PVCs, matching Compose's three separate bind mounts** — `state` (`/home/node/.openclaw`), `workspace` (`/home/node/.openclaw/workspace`, nested under state — same nesting Compose had via two separate bind mounts), `auth-secrets` (`/home/node/.config/openclaw`, empty on this install — auth key material was never actually populated here).

**A real, pre-existing app-level migration step surfaced (not caused by k8s)** — on first boot with real data restored, the gateway crash-looped: `Legacy workspace setup state requires migration for /home/node/.openclaw/workspace; run openclaw doctor --fix`. This is the `latest` image's own workspace-format migration, unrelated to the k8s move — likely would have hit the same wall on a Compose `docker compose pull && up -d` too, since the image tag floats. Fixed with a one-off pod (same image, same three PVCs mounted, `command: ["node", "dist/index.js", "doctor", "--fix"]` overriding the gateway's default args) run to completion, then deleted. `doctor --fix` also flagged two informational, unrelated items (no `OPENAI_API_KEY` for semantic memory search, legacy device-pairing JSON files not yet imported to SQLite — both expected to resolve or stay benign on the gateway's own next startup) and updated `openclaw.json` in place (with a `.bak` written automatically).

**Data migration (verified)** — `state` (8312 files), `workspace` (55 files, includes its own git repo), `auth-secrets` (1 file — a placeholder, real key material was never populated on this install). All three matched exact file counts; md5sum verified on `openclaw.json` and `SOUL.md`.

**Verified externally**: `https://openclaw.smugiwara.com/` → 200, serving the real control-UI HTML shell (its own login screen handles the `OPENCLAW_GATEWAY_TOKEN` prompt client-side, same as hermes-dashboard). Gateway logs confirm `[gateway] ready`, and the Telegram channel reconnected (`[telegram] starting provider (@mugiwara_openclaw_bot)`), confirming the bot token in the migrated secrets/config is intact and live.

**Secrets** — `OPENCLAW_GATEWAY_TOKEN`, `OPENROUTER_API_KEY`, `TELEGRAM_BOT_TOKEN` are a `SealedSecret` (`helm/openclaw/templates/sealed-secrets.yaml`), sealed directly from `openclaw.env` — never displayed, never a plaintext in-cluster Secret. No separate edge-level token is needed (see the Ingress correction above) — `OPENCLAW_GATEWAY_TOKEN` is entered directly into the app's own login screen.

**Sandbox mode still off** — same as Compose, no docker-socket mount for `agents.defaults.sandbox`; not something to add lightly in a shared cluster context (blast radius would extend to the whole node, not just this container, if ever enabled).
