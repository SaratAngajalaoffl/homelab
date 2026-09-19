# jeeva — manual bootstrap notes

Source: [SaratAngajalaoffl/jeeva](https://github.com/SaratAngajalaoffl/jeeva) (private repo). Three
services (Next.js `frontend`, Express `api`, Rust `engine`) plus MongoDB (config/state, needs a
single-node replica set for change streams) and TimescaleDB (market data / decisions / positions).
Images publish to `ghcr.io/saratangajalaoffl/jeeva/{api,engine,frontend}` on every push to `main`
via `.github/workflows/publish.yml` in that repo. That workflow only ever tags `main` — despite
`docker/metadata-action`'s docs describing a `latest=auto` flavor, that only fires for semver-tag
pushes, not branch pushes, so **there is no `:latest` tag published** (confirmed by inspecting a
successful publish run's `DOCKER_METADATA_OUTPUT_TAGS` output — it only ever contains
`...:main`). This chart pins images to `main` (not digest-pinned yet — see "GHCR pull secret"
below) and, once pinned, Renovate bumps the digest, same pattern as `helm/yggdrasil`. That's what
gets you "updates when I push to main": push → GHCR publishes a new `main` digest → Renovate opens
a digest-bump PR → CI passes → automerges → ArgoCD's `selfHeal` picks it up.

## Blocker 1 — GHCR pull secret (not yet created)

The jeeva images are **private**, so nothing in `homelab-jeeva` can pull them without an
`imagePullSecret` named `ghcr-jeeva` (already wired into every Deployment in `values.yaml`). To
create it:

1. On GitHub, create a **classic PAT** scoped to `read:packages` only
   (github.com/settings/tokens) — do not reuse a broader token.
2. `kubectl create secret docker-registry ghcr-jeeva -n homelab-jeeva --dry-run=client -o json --docker-server=ghcr.io --docker-username=<your-gh-username> --docker-password=<the-PAT> > /tmp/ghcr-jeeva.json`
3. `kubeseal --cert <(kubeseal --fetch-cert --controller-namespace kube-system --controller-name sealed-secrets-controller) --format yaml < /tmp/ghcr-jeeva.json > helm/jeeva/templates/sealed-ghcr-pull-secret.yaml`
4. Fix up the `template.metadata.name`/`namespace` and add `type: kubernetes.io/dockerconfigjson`
   under `template`, matching the shape of the other `sealed-*.yaml` files in this chart.
5. `shred -u /tmp/ghcr-jeeva.json`, commit the sealed file, push.

Until this exists, every pod here will sit in `ImagePullBackOff`. **Done as of 2026-09-20** — the
secret exists and pulls are authenticating fine now; the `ImagePullBackOff` seen right after was
actually blocker "0" below, not this one.

## Blocker 0 — images aren't digest-pinned yet (tag is "main", mutable)

`api`/`engine`/`frontend` are currently pinned to the tag `main`, not a digest, because resolving
the digest needs the same `ghcr-jeeva` PAT and I (the agent) never hold that token — only you do.
To pin it properly (recommended, matches every other stack in this repo):

```bash
echo <PAT> | docker login ghcr.io -u <gh-username> --password-stdin
docker pull ghcr.io/saratangajalaoffl/jeeva/api:main
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/saratangajalaoffl/jeeva/api:main
# repeat for engine and frontend
```

Then update each `tag:` in `values.yaml` to `"main@sha256:<digest>"`. Until then, `imagePullPolicy`
defaults to `IfNotPresent`, so a running pod won't silently drift — but a fresh pod scheduled after
a new push could pull a different `main` than what's been tested.

## Blocker 2 — no production migration path in the published image

`api/deploy/Dockerfile` (in the jeeva repo) only copies `dist/`, `node_modules/`, and
`package.json` into the runtime image — it never copies `api/migrations/` or the `tsx`/
`node-pg-migrate` devDependencies the `migrate` script needs. So there's no way to run
`npm run migrate up` from the published `api` image. Until that's fixed upstream (adding the
migrations dir + `node-pg-migrate` to the deploy image, or a dedicated migrate stage), run
migrations manually from a local checkout after port-forwarding to the cluster:

```bash
KUBECONFIG=~/.kube/k3s-homelab.yaml kubectl -n homelab-jeeva port-forward svc/jeeva-timescaledb 5432:5432 &
DATABASE_URL=postgres://<user>:<password>@localhost:5432/<db> npm run migrate --workspace=api up
```

(Credentials are whatever's sealed into `jeeva-db-secrets`; you have them from when you sealed
that secret.) Needed once now, and again after any PR in the jeeva repo that adds a migration
file.

## Frontend API URL is baked at build time

`frontend/src/lib/api.ts` reads `process.env.NEXT_PUBLIC_API_URL` — Next.js inlines
`NEXT_PUBLIC_*` vars into the static JS bundle **at build time**, and `frontend/deploy/Dockerfile`
never receives it as a build arg, nor does `publish.yml` pass one. So the shipped image's browser
bundle always calls its baked-in fallback, `http://localhost:4000`, regardless of the
`NEXT_PUBLIC_API_URL` env var set on this chart's `frontend` container (which only affects
server-side code, e.g. Next SSR, not the client fetch calls in `api.ts`). **The public dashboard
at jeeva.smugiwara.com will not be able to reach the API until this is fixed upstream** — either
pass `--build-arg NEXT_PUBLIC_API_URL=https://jeeva-api.smugiwara.com` in `publish.yml`'s
`docker/build-push-action` step (and read it via `ARG`/`ENV` in the Dockerfile before `next
build`), or switch the frontend to same-origin relative API calls behind a shared Ingress path.
Not something fixable from this repo — it needs a jeeva-repo change.

## Renovate and private GHCR

Renovate needs its own credentials to read digests from `ghcr.io/saratangajalaoffl/jeeva/*` —
being able to `git push` to this repo doesn't imply read access to a different private repo's
GHCR packages. If the automated digest-bump PRs mentioned above never appear, add a `hostRules`
entry (or your Renovate app's private-package config) granting it a `read:packages` token for
that image path — same PAT as blocker 1 above, or a separate narrowly-scoped one.

## Mongo replica set

`templates/mongo-rs-init-job.yaml` is a Helm post-install/post-upgrade hook Job that runs the same
idempotent `rs.initiate()` script docker-compose.yml's `mongo-init` service used — safe to rerun
every deploy, no manual step needed.

## What's deliberately not wired up yet

- `TYPESAFE_API_KEY` / `TYPESAFE_BASE_URL` / `HYPERLIQUID_PRIVATE_KEY` / `HYPERLIQUID_TESTNET` are
  not set in `jeeva-engine-secrets` — the engine starts fine without them (Fake DecisionMaker,
  mock execution, per the app's own defaults) and the dashboard's typesafe/live switches just stay
  inert until you add them. Add keys to that Secret (reseal, same as any other sealed secret in
  this chart) when you're ready.
- No PVC backup exemption needed for `arr`/`jellyfin`-style hostPath media — jeeva has none; both
  databases get Velero pre-backup dump hooks per the repo-wide rule.
