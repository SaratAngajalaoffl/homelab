# Homelab Context

## Glossary

**Stack** — a self-contained Helm chart in `helm/<name>/`, with its own `Chart.yaml`, `values.yaml`, and templates. Deployed into its own `homelab-<name>` namespace. Examples: `arr`, `immich`. (Pre-migration, a stack was a Docker Compose project in `containers/<name>/` — see `docs/adr/0004-kubernetes-migration.md` for the transition.)

**Chart** — the Helm chart inside a stack directory (`helm/<name>/Chart.yaml` + `templates/`). Each stack is deployed independently, either by ArgoCD reconciliation or manually via `helm upgrade --install`.

**`homelab-common`** — the shared library chart (`helm/homelab-common/`) holding common templates (Deployment, Service, PVC, Ingress, standard labels/namespace conventions) so each stack's chart mostly supplies a `values.yaml` rather than hand-writing manifests from scratch.

**Sealed Secret** — a `SealedSecret` manifest (`helm/<stack>/templates/sealed-*.yaml`), encrypted client-side with `kubeseal` against the in-cluster Sealed Secrets controller's public key. Safe to commit — only that controller can decrypt it. Replaces the pre-migration `*.env`/`.setup` secrets pattern for any stack that has adopted it (see `helm/atuin` for the reference pattern).

**`values.secret.yaml`** — a gitignored per-stack secrets file (for stacks not yet on Sealed Secrets), copied from a committed `values.secret.example.yaml` template. Direct analog of the old `*.env`/`*.example` pair.

**Secrets export** — `scripts/k8s-secrets/copy_secrets.sh`. Backs up the Sealed Secrets controller's signing key(s) plus any not-yet-sealed plaintext Secret across `homelab-*` namespaces to the clipboard as JSON, for storing in a vault. `scripts/env/copy_env.sh` is the older equivalent for any remaining plaintext `*.env`/`values.secret.yaml` files.

**Secrets restore** — `scripts/k8s-secrets/apply_secrets.sh`. Reads the exported JSON (stdin or clipboard) and restores the controller's key(s) plus plaintext secrets into a rebuilt cluster, restarting the controller so it picks up the restored key. Must run right after installing the Sealed Secrets controller, before anything else references it.

**homelab-conf** — host path `${HOME}/storage/homelab/homelab-conf/`. Holds app configuration, databases, and small persistent state. Bound into pods via PVC (local-path-provisioner). Never committed to git.

**homelab-data** — host path `${HOME}/storage/homelab/homelab-data/`. Holds bulk user-generated content (torrents, media libraries, photo libraries, Nextcloud files). Bound into pods via PVC (local-path-provisioner). Never committed to git.

**ArgoCD app-of-apps** — `helm/argocd/root-app.yaml` (the one manually-applied Application) plus `helm/argocd/apps/<stack>.yaml` (one child Application per migrated stack). `git push` to `main` is the deploy step: editing `helm/<stack>/` or `helm/argocd/apps/` and pushing triggers ArgoCD's automated sync (`prune: true, selfHeal: true`). See `helm/argocd/CONTEXT.md`.

**Gluetun** — VPN sidecar container in the `arr` stack's single pod. All arr-suite containers share that pod's network namespace natively (k8s equivalent of Compose's `network_mode: "service:gluetun"`), so every app routes through ProtonVPN WireGuard just by being in the pod.

**VPN-routed service** — a container inside the `arr` pod, routed through the Gluetun sidecar's tunnel. Includes qBittorrent, Sonarr, Radarr, Prowlarr, FlareSolverr, and Homarr.

**PUID/PGID (`runAsUser`/`fsGroup`)** — LinuxServer.io images in the `arr` stack run as UID/GID `1000` (k8s `securityContext.runAsUser`/`fsGroup`) to match a typical desktop user's ownership on PVC-backed paths derived from `$HOME`.

**Ingress** — the k8s `Ingress`/`IngressRoute` resource in a stack's chart, handled by Traefik (bundled with k3s) + `cert-manager` for TLS. Replaces `nginx-proxy-manager`'s GUI-based proxy-host config; routing lives in git instead of NPM's SQLite state. See `docs/adr/0004-kubernetes-migration.md`.

**Renovate** — `renovate.json` at repo root. Bot that scans `helm/*/values.yaml` for `image.repository`/`image.tag` pairs and opens a PR per available update, so keeping k3s workloads current is "review and merge a PR" instead of manually diffing registries. Pinned DB/stateful images (Immich, Atuin, Postgres, valkey) get a longer `minimumReleaseAge` and no automerge; floating tags (`latest`/`main`) get digest-only pin PRs instead of tag bumps, since there's no tag to bump. Requires the Renovate GitHub App installed on the repo (or a self-hosted runner). This is the closest equivalent to the retired `watchtower` monitor — awareness now arrives as a PR against git rather than a notification about a running container.

**netbird** — `helm/netbird/`. Self-hosted mesh VPN control plane (`netbird-server` + `dashboard`), trimmed to just those two — no routing peer, no external IdP, no coturn. Purpose is narrow: let an enrolled laptop reach this host's SSH port over an encrypted overlay network without ever exposing `22/tcp` to the internet. The host itself joins the mesh via a native systemd `netbird` client, not a pod.

**k3s / Traefik** — the k3s distribution bundles Traefik as its default ingress controller with a `LoadBalancer` Service (`ServiceLB`/klipper), which will hijack host ports 80/443 from any competing listener the moment k3s installs or upgrades. Must be patched to `ClusterIP` unless Traefik is meant to be the sole public listener (see ADR 0004's consequences section for the incident this caused).
