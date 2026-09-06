# Homelab Context

## Glossary

**Stack** — a self-contained Helm chart in `helm/<name>/`, with its own `Chart.yaml`, `values.yaml`, and templates. Deployed into its own `homelab-<name>` namespace. Examples: `arr`, `immich`. (Pre-migration, a stack was a Docker Compose project in `containers/<name>/` — see `docs/adr/0004-kubernetes-migration.md` for the transition.)

**Chart** — the Helm chart inside a stack directory (`helm/<name>/Chart.yaml` + `templates/`). Each stack is deployed independently, either by ArgoCD reconciliation or manually via `helm upgrade --install`.

**`homelab-common`** — the shared library chart (`helm/homelab-common/`) holding common templates (Deployment, Service, PVC, Ingress, standard labels/namespace conventions) so each stack's chart mostly supplies a `values.yaml` rather than hand-writing manifests from scratch.

**Sealed Secret** — a `SealedSecret` manifest (`helm/<stack>/templates/sealed-*.yaml`), encrypted client-side with `kubeseal` against the in-cluster Sealed Secrets controller's public key. Safe to commit — only that controller can decrypt it. Replaces the pre-migration `*.env`/`.setup` secrets pattern for any stack that has adopted it (see `helm/atuin` for the reference pattern).

**`values.secret.yaml`** — a gitignored per-stack secrets file, copied from a committed `values.secret.example.yaml` template. **No longer used by any stack.** The last two consumers (`ollama`, `hermes`) needed a token inside a Traefik routing rule, which ArgoCD could never render from a gitignored file — see `helm/token-auth`. Secrets are either SealedSecrets or created out-of-band as real Secrets (`velero`, `token-auth`, `backup-local`), and the leftover `helm/ollama/values.secret.yaml` / `helm/hermes/values.secret.yaml` files can be deleted.

**Secrets export** — `scripts/k8s-secrets/copy_secrets.sh`. Backs up the Sealed Secrets controller's signing key(s) plus any not-yet-sealed plaintext Secret across `homelab-*` **and `velero`** to the clipboard as JSON, for storing in a vault. The `velero` namespace matters most: it holds the S3 credential for the bucket the backups are in, so omitting it (as this script originally did) means a rebuilt cluster cannot reach its own backups. `scripts/env/copy_env.sh` is the older equivalent for any remaining plaintext `*.env`/`values.secret.yaml` files.

**Secrets restore** — `scripts/k8s-secrets/apply_secrets.sh`. Reads the exported JSON (stdin or clipboard) and restores the controller's key(s) plus plaintext secrets into a rebuilt cluster, restarting the controller so it picks up the restored key. Must run right after installing the Sealed Secrets controller, before anything else references it.

**local-path root** — `/var/lib/rancher/k3s/storage/` on the OS disk (`nvme1n1p2`). Where every PVC in this cluster actually lives: all of them use the stock `local-path` StorageClass, so they are dynamically provisioned under this single root as `pvc-<uid>_<namespace>_<pvc-name>`. There are no static PVs in this repo. One consequence worth knowing: because it is one root, `helm/backup-local`'s restic job captures every PVC on the cluster with a single read-only mount.

**homelab-conf / homelab-data** — `${HOME}/storage/homelab/homelab-conf|data/`, ADR 0002's config-vs-content split. **Historical for PVCs.** Nothing points a PVC at these paths and the directories do not currently exist; the dedicated 932G disk mounted at `~/storage` sits at ~1% used, while all PVC data is on the OS disk under the local-path root above. The convention survives only in the `hostPath` mounts that still name it (`arr`'s `dataHostPath`, `jellyfin`'s media mount). See `docs/adr/0005-backup-restore.md` "Known gaps".

**Backup (cloud)** — `helm/velero`. Weekly Velero Schedule (`0 3 * * 0`) backing up all namespaces to S3: Kubernetes objects plus PVC data via Kopia file-system backup. Restores can rebuild namespaces, Secrets and PVCs, not just files.

**Backup (local)** — `helm/backup-local`. Weekly restic CronJob (`0 4 * * 0`) writing an encrypted repository to the munin external drive. File-level only, but restorable from any machine with the drive and the password — no cluster required. restic rather than a Velero BSL because the drive is exFAT, which MinIO (the only way to give Velero an S3 endpoint on local disk) does not support.

**Backup hook** — a `pre.hook.backup.velero.io` pod annotation that dumps a database to a dedicated `dumps` PVC before Kopia walks it. Kopia has no snapshot or freeze, so copying a live Postgres data directory produces a torn backup. Every database stack has one; `homelab-common`'s `podAnnotations` support exists specifically to make them expressible.

**Backup watchdog** — a CronJob in `helm/backup-local` that pings healthchecks.io daily only while the newest completed Velero backup is under 8 days old. A dead-man's switch: failure, partial failure, or a dead cluster all produce silence, and silence is the alert.

**ArgoCD app-of-apps** — `helm/argocd/root-app.yaml` (the one manually-applied Application) plus `helm/argocd/apps/<stack>.yaml` (one child Application per migrated stack). `git push` to `main` is the deploy step: editing `helm/<stack>/` or `helm/argocd/apps/` and pushing triggers ArgoCD's automated sync (`prune: true, selfHeal: true`). See `helm/argocd/CONTEXT.md`.

**Gluetun** — VPN sidecar container in the `arr` stack's single pod. All arr-suite containers share that pod's network namespace natively (k8s equivalent of Compose's `network_mode: "service:gluetun"`), so every app routes through ProtonVPN WireGuard just by being in the pod.

**VPN-routed service** — a container inside the `arr` pod, routed through the Gluetun sidecar's tunnel. Includes qBittorrent, Sonarr, Radarr, Prowlarr, FlareSolverr, and Homarr.

**PUID/PGID (`runAsUser`/`fsGroup`)** — LinuxServer.io images in the `arr` stack run as UID/GID `1000` (k8s `securityContext.runAsUser`/`fsGroup`) to match a typical desktop user's ownership on PVC-backed paths derived from `$HOME`.

**Ingress** — the k8s `Ingress`/`IngressRoute` resource in a stack's chart, handled by Traefik (bundled with k3s) + `cert-manager` for TLS. Replaces `nginx-proxy-manager`'s GUI-based proxy-host config; routing lives in git instead of NPM's SQLite state. See `docs/adr/0004-kubernetes-migration.md`.

**Renovate** — `renovate.json` at repo root. Bot that scans `helm/*/values.yaml` for `image.repository`/`image.tag` pairs and opens a PR per available update, so keeping k3s workloads current is "review and merge a PR" instead of manually diffing registries. Pinned DB/stateful images (Immich, Atuin, Postgres, valkey) get a longer `minimumReleaseAge` and no automerge; floating tags (`latest`/`main`) get digest-only pin PRs instead of tag bumps, since there's no tag to bump. Requires the Renovate GitHub App installed on the repo (or a self-hosted runner). This is the closest equivalent to the retired `watchtower` monitor — awareness now arrives as a PR against git rather than a notification about a running container.

**netbird** — `helm/netbird/`. Self-hosted mesh VPN control plane (`netbird-server` + `dashboard`), trimmed to just those two — no routing peer, no external IdP, no coturn. Purpose is narrow: let an enrolled laptop reach this host's SSH port over an encrypted overlay network without ever exposing `22/tcp` to the internet. The host itself joins the mesh via a native systemd `netbird` client, not a pod.

**k3s / Traefik** — the k3s distribution bundles Traefik as its default ingress controller with a `LoadBalancer` Service (`ServiceLB`/klipper), which hijacks host ports 80/443 from any competing listener. That caused a real outage when it silently took traffic from `nginx-proxy-manager` (ADR 0004's consequences section). **That is now the desired behaviour**: NPM is retired and Traefik is the sole public listener, so its Service must stay `LoadBalancer`. ADR 0004's instruction to patch it to `ClusterIP` is obsolete and would take every service offline.

**Rate-limit middleware** — a Traefik `rateLimit` Middleware (20/s average, 40 burst) attached to each publicly-exposed admin UI (`argocd`, `headlamp`, `portainer`, the `arr` routes, `openclaw`). A credential-stuffing mitigation, explicitly not a fix; the agreed target state is netbird-only access for all of them. Middlewares are namespaced and k3s's Traefik runs with `allowCrossNamespace` off, so each namespace gets its own copy. See `docs/adr/0005-backup-restore.md`.

**ForwardAuth / token-auth** — `helm/token-auth`, a small service Traefik consults before forwarding a request to `ollama` or `hermes`'s public API. Holds a per-host bearer-token map in a Secret and compares in constant time. Replaced a scheme that interpolated the token into the IngressRoute matcher itself from a gitignored values file — which ArgoCD could not render, so the rule became `^Bearer $` and matched nothing.
