# searxng Stack Context

## Glossary

**searxng-stack** — compose project `searxng-stack` in `containers/searxng/`. Self-hosted SearXNG metasearch engine, shared web-search backend for `webui`, `openclaw`, `hermes`.

**k8s migration** — `~/homelab/helm/searxng/` holds this stack's Helm chart, converted per `docs/adr/0004-kubernetes-migration.md`. One Deployment (`server`) via `helm/homelab-common`, one Ingress (`websearch.smugiwara.com`) gated by a Traefik `Middleware` (`basicAuth`), the k8s-native equivalent of NPM's Access List. Live production deployment as of 2026-09-06; Compose stack was already stopped before this migration.

**Basic Auth via Traefik `Middleware` + Secret** — unlike ollama's bearer-token IngressRoute hack (needed because the token had to be a literal string in a routing rule), Traefik's `basicAuth` middleware natively reads htpasswd-format credentials from a k8s Secret (`data.users`, one `user:apr1-hash` line per entry), referenced by name (`spec.basicAuth.secret: searxng-basic-auth`) — no literal-value workaround needed. The Ingress references the middleware via the annotation `traefik.ingress.kubernetes.io/router.middlewares: homelab-searxng-basic-auth@kubernetescrd` (`<namespace>-<middleware-name>@kubernetescrd`). **This is now the reference pattern for any future stack needing real Basic Auth** — much cleaner than ollama's bearer-token approach.

**Reused the existing credentials** — same `mugiwara` username/password from NPM's Access List, provided directly by the user and sealed via `kubeseal` (hashed with `openssl passwd -apr1` first) into `helm/searxng/templates/sealed-basic-auth.yaml` — plaintext was never written to a k8s Secret directly, only ever piped through `kubectl create secret ... --dry-run=client -o yaml | kubeseal`.

**Fresh-install trap caught again** (3rd time — same pattern as nextcloud/netbird) — the official image's entrypoint copies its bundled `settings.template.yml` into an empty `/etc/searxng` on first boot, generating a brand-new random secret key. Caught by checking the file size before assuming the deployment was ready (fresh: 205 bytes vs. the real host file's 245 bytes, which has the `search.formats: [html, json]` block already added — see the stack's original `.setup` step 2). Fixed with the same busybox-migrate-pod recipe: scale to 0, wipe the fresh `settings.yml`, copy the real one in from `homelab-conf/searxng/config`, verify md5sum match, scale back to 1.

**Data migration (verified)** — `settings.yml` (245 bytes) — single file, md5sum exact match, uid/gid 977 (the image's built-in `searxng` user) preserved through the copy.

**Verified externally**: unauthenticated request → 401; with `mugiwara` credentials → 200; JSON API (`?format=json`) returns real search results through the Basic Auth gate — confirms both the auth middleware and the JSON-format config (already present in the migrated `settings.yml`) work correctly.

**Consumers not yet updated** — `webui`, `openclaw`, `hermes` still point at the old Compose `searxng:8080` container-name DNS. `webui`'s `SEARXNG_QUERY_URL` will be updated to the in-cluster service name as part of its own migration (next); `openclaw`/`hermes` aren't migrated yet and will need the same update when they are.
