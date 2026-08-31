# yggdrasil Stack Context

## Glossary

**yggdrasil-stack** — compose project `yggdrasil-stack` in `containers/yggdrasil/`. Self-hosted deploy of [yggdrasil-hq/yggdrasil-core](https://github.com/yggdrasil-hq/yggdrasil-core), an AI-orchestrated software development platform: describe a feature in plain language, an agent creates a branch and opens a PR against a linked GitHub repo. **This is the user's own actively-developed app**, not a third-party service — the upstream repo is early/pre-alpha (created 2026-06-09, no `vX.Y.Z` releases yet).

**Not the mesh-networking Yggdrasil** — do not confuse with `yggdrasil-network/yggdrasil-go`. Unrelated project, same name.

**Five control-plane services**, all pulled from GHCR (`ghcr.io/yggdrasil-hq/yggdrasil-<name>:latest`) rather than built from source, per the "Self-hosting from published images" path in upstream's `docs/conventions/deploy.md`:
- **landing** — marketing site, no app config.
- **web** — Next.js app UI.
- **docusaurus** — user-facing docs site.
- **api** — Express API + Postgres, owns GitHub OAuth sign-in and project/job state.
- **orchestrator** — Go service that claims jobs from the same Postgres `jobs` table and drives them on a k3s cluster configured in-app (see below). Per upstream ADR 003 it targets a Kubernetes API, not a Docker socket — this is a deliberate upstream architecture choice, not something this stack works around.

**GHCR packages are private by default** — pulling any of the five images (plus `yggdrasil-agent-images`) needs `docker login ghcr.io` with a PAT that has `read:packages`, until the user flips each package to public in its repo's package settings (intent: they should be public). See `.setup`.

**No bundled nginx** — upstream's `deploy/docker-compose.prod.yml` ships its own nginx reverse proxy trusting `X-Forwarded-*`. This stack skips it entirely: `landing`, `web`, `docusaurus`, `api`, and `orchestrator` join the external `edge` network directly instead, and get one NPM proxy host each, same pattern as every other stack in this repo (see root `CLAUDE.md`).

**yggdrasil_net** — private bridge network for service-to-service traffic (api ↔ postgres/minio/orchestrator), mirroring `immich`'s `immich_net` pattern rather than relying on the default per-project network.

**k3s cluster — configured in-app, not part of this compose project.** The Orchestrator needs *some* Kubernetes cluster to target. This stack previously bundled its own disposable `k3s` + `k3s-kubeconfig` services (lifted from upstream's `deploy/docker-compose.dev.yml`), then briefly relied on an operator-supplied kubeconfig file; both were removed — kubeconfig and cluster targeting are now supplied through the yggdrasil web app itself, not via any file, env var, or volume in this compose project.

**Project-deployment ingress — NOT wired up yet.** Per-project deployments (`<project-slug>.apps.${APPS_BASE_DOMAIN}`, ADR 003 §15) live on whatever ingress controller the target cluster runs, which this compose file does **not** publish to the host. Upstream's own docs mark this whole area (agent-chat routing, primary-deployment TLS) as draft/TODO. Exposing it for real needs a decision this repo hasn't made yet: a wildcard NPM proxy host + real wildcard cert (would require DNS-01, not the HTTP-01 every other proxy host here uses) vs. a raw non-standard host-port carve-out. Revisit when the user is actually ready to view a deployed project from outside this host — until then, "Open deployment" links from the web UI won't resolve.

**Agent-images (`SPEC_GRILL_IMAGE`/`FEATURE_BUILD_IMAGE`/`TEST_RUN_IMAGE`)** — per-job-kind images the Orchestrator schedules on the target cluster to actually run agent work. Commented out in `yggdrasil.example` until `yggdrasil-hq/yggdrasil-agent-images` publishes them; a job kind left unset has no working fallback in this stack (upstream's `JOB_PLACEHOLDER_IMAGE`/`_SCRIPT` dev stand-in isn't set here either). Pulling these on the *target cluster* needs its own `imagePullSecret` if they stay private — separate from the `docker login` on the host used to pull the five control-plane images — upstream tracks this as an open follow-up, not automated here.

**GitHub OAuth vs GitHub App** — two separate GitHub-side registrations, easy to conflate:
- OAuth App (`GITHUB_CLIENT_ID`/`_SECRET`) — sign-in only, required for the API to even boot the auth flow (ADR 009).
- GitHub App (`GITHUB_APP_ID`/`_SLUG`/`_PRIVATE_KEY`/`_WEBHOOK_SECRET`, commented out by default) — repo access (installations, webhooks, job tokens) so the Orchestrator can actually open branches/PRs. Sign-in works without it; agent PRs don't.

**Storage**:
- `homelab-conf/yggdrasil/postgres` → api's Postgres data
- `homelab-data/yggdrasil/minio` → MinIO artifact storage (bulk, not config/state)

**Secrets** — `yggdrasil.env` (Postgres/MinIO creds, `SECRETS_ENCRYPTION_KEY`, `INTERNAL_API_TOKEN`, `SESSION_SECRET`, GitHub OAuth/App credentials) is gitignored, never read or committed by an agent. Covered by `scripts/env/copy_env.sh` like every other `*.env` file.

**Domain** — proxy hosts suggested in `.setup`: `app.yggdrasil.cfd`, `api.yggdrasil.cfd`, `docs.yggdrasil.cfd`. Unlike every other stack in this repo (migrated to `smugiwara.com`), yggdrasil keeps `yggdrasil.cfd` deliberately — it's the app's own name.
