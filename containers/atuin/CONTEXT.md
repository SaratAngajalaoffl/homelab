# atuin Stack Context

## Glossary

**atuin-stack** — compose project `atuin-stack` in `containers/atuin/`. Self-hosted [Atuin](https://atuin.sh) sync server, so shell history recorded by the Atuin CLI on the Arch desktop and a MacBook merges instead of staying two separate local histories.

**atuin_server** — `ghcr.io/atuinsh/atuin` image, `command: server start`. Stateless itself; all history and account data live in `atuin-db`. Talks plain HTTPS/JSON, so unlike `netbird`'s combined server it needs no gRPC/websocket carve-out in the NPM proxy host — a normal proxy host with HTTP/1.1 is enough.

**atuin-db** — `postgres:18`. Dedicated instance, not shared with any other stack's postgres (immich and nextcloud each have their own too) — matches the one-stack-one-database convention already in use.

**Encryption model** — history is end-to-end encrypted client-side with a key generated at first `atuin register`/`login`, never sent to the server. The server only ever sees ciphertext plus metadata (timestamps, session IDs). This is why it's safe to expose on the same public `*.smugiwara.com` + NPM pattern as every other stack, rather than requiring `netbird`'s private overlay — compromising the server doesn't expose plaintext command history, only account existence and encrypted blobs.

**Registration gate** — `ATUIN_OPEN_REGISTRATION` in `atuin.env` is `true` only during initial machine enrollment, then flipped to `false` (see `.setup`). There's no other access control in front of `/register` while it's `true` besides NPM's TLS termination — the domain is public.

**Sync scope** — one account, logged into from both the Arch desktop and the MacBook with the same encryption key (`atuin key` on the first machine, `atuin login -k` on the rest). Atuin doesn't do per-machine accounts; multi-device sync is inherent to a single account having multiple logged-in clients.

**`edge` network** — only `atuin_server` joins it; `atuin-db` stays on the stack-internal `atuin_net` bridge, unreachable from outside the stack. Same shape as `immich_net` / `immich-server`+`database`.

**Data** — Postgres data at `homelab-conf/atuin/db`, atuin server's own config (if any gets written) at `homelab-conf/atuin/config`. No `homelab-data` usage — encrypted history blobs are config-scale, not bulk content.

**k8s migration** — `~/homelab/helm/atuin/` holds this stack's Helm chart (charts live under a top-level `helm/` directory, not inside `containers/`), the first stack converted per `docs/adr/0004-kubernetes-migration.md`. It depends on the shared `helm/homelab-common` library chart for Deployment/StatefulSet/Service/PVC/Ingress templates. This is now the **live production deployment** — the Compose stack above is fully stopped, and `atuin.smugiwara.com` serves directly off k3s/Traefik with a real Let's Encrypt cert (cutover completed 2026-09-06, real Postgres data migrated via `pg_dump`/restore, row counts verified to match).

**Secrets** — `atuin-server-secrets` and `atuin-db-secrets` are committed as `SealedSecret` manifests (`helm/atuin/templates/sealed-*.yaml`), encrypted against the in-cluster Sealed Secrets controller — see the ADR's "Secrets (Sealed Secrets)" decision. To rotate a value: update the plaintext, re-run `kubectl create secret generic ... --dry-run=client -o yaml | kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --format yaml > helm/atuin/templates/sealed-<name>.yaml`, then `kubectl apply -f` it (or let ArgoCD pick it up, once that's live). Never write plaintext values into `values.yaml`.
