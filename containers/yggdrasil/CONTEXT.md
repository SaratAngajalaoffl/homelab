# yggdrasil Stack Context

## Glossary

**yggdrasil-stack** — compose project `yggdrasil-stack` in `containers/yggdrasil/`. Self-hosted deploy of [yggdrasil-hq/yggdrasil-core](https://github.com/yggdrasil-hq/yggdrasil-core), an AI-orchestrated software development platform: describe a feature in plain language, an agent creates a branch and opens a PR against a linked GitHub repo. **This is the user's own actively-developed app**, not a third-party service — the upstream repo is early/pre-alpha (created 2026-06-09, no `vX.Y.Z` releases yet).

**Not the mesh-networking Yggdrasil** — do not confuse with `yggdrasil-network/yggdrasil-go`. Unrelated project, same name.

**Five control-plane services**, all pulled from GHCR (`ghcr.io/yggdrasil-hq/yggdrasil-<name>:latest`) rather than built from source, per the "Self-hosting from published images" path in upstream's `docs/conventions/deploy.md`:
- **landing** — marketing site, no app config.
- **web** — Next.js app UI.
- **docusaurus** — user-facing docs site.
- **api** — Express API + Postgres, owns GitHub OAuth sign-in and project/job state.
- **orchestrator** — Go service that claims jobs from the same Postgres `jobs` table and drives them on the bundled k3s cluster (see below). Per upstream ADR 003 it targets a Kubernetes API, not a Docker socket — this is a deliberate upstream architecture choice, not something this stack works around.

**GHCR packages are private by default** — pulling any of the five images (plus `yggdrasil-agent-images`) needs `docker login ghcr.io` with a PAT that has `read:packages`, until the user flips each package to public in its repo's package settings (intent: they should be public). See `.setup`.

**No bundled nginx** — upstream's `deploy/docker-compose.prod.yml` ships its own nginx reverse proxy trusting `X-Forwarded-*`. This stack skips it entirely: `landing`, `web`, `docusaurus`, `api`, and `orchestrator` join the external `edge` network directly instead, and get one NPM proxy host each, same pattern as every other stack in this repo (see root `CLAUDE.md`).

**yggdrasil_net** — private bridge network for service-to-service traffic (api ↔ postgres/minio/orchestrator, orchestrator ↔ k3s), mirroring `immich`'s `immich_net` pattern rather than relying on the default per-project network.

**Bundled k3s** — the Orchestrator needs *some* Kubernetes cluster to target. Rather than requiring the user to stand up a separate cluster, this stack runs upstream's own dev-flow bundled `k3s` + `k3s-kubeconfig` services (lifted from `deploy/docker-compose.dev.yml`), just with `restart: unless-stopped` for a long-lived install instead of disposable dev use. `k3s` bundles Traefik as its ingress controller and local-path storage; `k3s-kubeconfig` rewrites its self-signed kubeconfig into a Docker-DNS-reachable form for the `orchestrator` container plus a host-side copy for `kubectl`.

**k3s API port (`31643`)** — bound to `127.0.0.1` only, not proxied through NPM. It's a raw TLS Kubernetes API (not HTTP-through-nginx-able) that grants full cluster-admin, so it gets the same loopback-only treatment as `nginx-proxy-manager`'s own admin UI — reach it via SSH tunnel, same as NPM's `81`.

**Project-deployment ingress — NOT wired up yet.** Per-project deployments (`<project-slug>.apps.${APPS_BASE_DOMAIN}`, ADR 003 §15) live on k3s's bundled Traefik, which this compose file does **not** publish to the host. Upstream's own docs mark this whole area (agent-chat routing, primary-deployment TLS) as draft/TODO. Exposing it for real needs a decision this repo hasn't made yet: a wildcard NPM proxy host + real wildcard cert (would require DNS-01, not the HTTP-01 every other proxy host here uses) vs. a raw non-standard host-port carve-out like the bundled dev setup uses (`8090`/`8443`, self-signed certs). Revisit when the user is actually ready to view a deployed project from outside this host — until then, "Open deployment" links from the web UI won't resolve.

**cert-manager + ClusterIssuer — one-time manual step.** k3s doesn't bundle cert-manager. Must be applied once via `kubectl` against the host-side kubeconfig before the orchestrator can issue any TLS cert for a project deployment (even the placeholder `selfSigned` one). See `.setup`.

**Agent-images (`SPEC_GRILL_IMAGE`/`FEATURE_BUILD_IMAGE`/`TEST_RUN_IMAGE`)** — per-job-kind images the Orchestrator schedules on k3s to actually run agent work. Commented out in `yggdrasil.example` until `yggdrasil-hq/yggdrasil-agent-images` publishes them; a job kind left unset has no working fallback in this stack (upstream's `JOB_PLACEHOLDER_IMAGE`/`_SCRIPT` dev stand-in isn't set here either). Pulling these on the *target cluster* (k3s) needs its own `imagePullSecret` if they stay private — separate from the `docker login` on the host used to pull the five control-plane images — upstream tracks this as an open follow-up, not automated here.

**GitHub OAuth vs GitHub App** — two separate GitHub-side registrations, easy to conflate:
- OAuth App (`GITHUB_CLIENT_ID`/`_SECRET`) — sign-in only, required for the API to even boot the auth flow (ADR 009).
- GitHub App (`GITHUB_APP_ID`/`_SLUG`/`_PRIVATE_KEY`/`_WEBHOOK_SECRET`, commented out by default) — repo access (installations, webhooks, job tokens) so the Orchestrator can actually open branches/PRs. Sign-in works without it; agent PRs don't.

**Storage**:
- `homelab-conf/yggdrasil/postgres` → api's Postgres data
- `homelab-conf/yggdrasil/k3s` → bundled k3s cluster state (`/var/lib/rancher/k3s`)
- `homelab-conf/yggdrasil/kube` → host-readable copy of the k3s kubeconfig (`kubectl`/cert-manager bootstrap)
- `homelab-data/yggdrasil/minio` → MinIO artifact storage (bulk, not config/state)

**Secrets** — `yggdrasil.env` (Postgres/MinIO creds, `SECRETS_ENCRYPTION_KEY`, `INTERNAL_API_TOKEN`, `SESSION_SECRET`, GitHub OAuth/App credentials) is gitignored, never read or committed by an agent. Covered by `scripts/env/copy_env.sh` like every other `*.env` file.

**Domain** — proxy hosts suggested in `.setup`: `app.yggdrasil.cfd`, `api.yggdrasil.cfd`, `docs.yggdrasil.cfd` (reusing the `yggdrasil.cfd` domain already in use for `netbird`/`hermes`/others — coincidental naming overlap with the app itself, not a conflict since NPM routes by full hostname).
