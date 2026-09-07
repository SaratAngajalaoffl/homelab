# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Detached homelab repo at `~/homelab` for self-hosted infrastructure running on a k3s cluster (originally an Arch Linux desktop single-node Docker Compose setup, migrated to Kubernetes per `docs/adr/0004-kubernetes-migration.md`). It is separate from `~/dotfiles-arch` (desktop dotfiles).

The repo owns Helm charts (`helm/<stack>/`), ArgoCD app-of-apps manifests, and the env/secrets round-trip scripts. It does **not** own runtime data (`~/storage/homelab/`, now backing PVCs via local-path-provisioner) or secrets (plaintext `*.env`/`values.secret.yaml`, or the Sealed Secrets controller's private key).

## Key commands

```bash
# Deploy: git push to main is the deploy step for every ArgoCD-managed stack —
# ArgoCD watches helm/argocd/apps/ and reconciles automatically. No manual
# `helm upgrade --install` for anything already onboarded there.
git push

# Manual helm invocation — only for bootstrapping a brand-new stack before it
# has an ArgoCD Application, or for infra ArgoCD doesn't manage (cert-manager,
# sealed-secrets-controller, nvidia-device-plugin, Traefik, ArgoCD itself).
helm upgrade --install <stack> ./helm/<stack> -n homelab-<stack> --create-namespace

# Export all secrets (*.env leftovers + Sealed Secrets controller key + any
# not-yet-sealed plaintext Secret across homelab-* AND velero) to clipboard as
# JSON — human secrets workflow. The velero namespace holds the credential for
# the bucket the backups live in; without it a rebuilt cluster cannot read them.
./scripts/env/copy_env.sh
./scripts/k8s-secrets/copy_secrets.sh

# Backup status — both destinations, one read-only view (safe mid-backup)
./scripts/backup/status.sh

# Backups. Cloud is automatic (weekly Schedule); everything else is manual.
velero backup get
velero backup create cloud-manual-$(date +%Y%m%d) --storage-location cloud
velero restore create --from-backup <backup-name>
kubectl -n homelab-backup-local create job --from=cronjob/backup-local manual-$(date +%Y%m%d)

# Restore from JSON (stdin or clipboard)
./scripts/env/apply_env.sh
./scripts/k8s-secrets/apply_secrets.sh
```

## Rules for agents

- **Never read, write, or commit `*.env` / `values.secret.yaml` files, or Sealed Secrets private keys**, during normal agent work. They are gitignored and contain secrets. Exception: only run `scripts/env/copy_env.sh`, `scripts/env/apply_env.sh`, `scripts/k8s-secrets/copy_secrets.sh`, or `scripts/k8s-secrets/apply_secrets.sh` when the user explicitly asks for secrets export/restore.
- **Never run `kubectl`/`helm` against any context other than the homelab k3s cluster.** Always check `kubectl config current-context` first; the user's kubeconfig may also point at real work EKS clusters, which must never be targeted from this repo's tooling.
- **May update `values.secret.example.yaml` files** when adding new required secret keys for a stack that hasn't migrated to Sealed Secrets yet. Keep placeholders empty or clearly marked.
- **May create or update `CONTEXT.md` / non-obvious setup notes** inside a stack's `helm/<stack>/` directory for manual bootstrap instructions that can't be expressed as chart values (see `helm/argocd/CONTEXT.md` for the pattern).
- **Storage reality — PVCs land on the OS disk, not the data disk.** Every PVC uses the stock `local-path` StorageClass, which provisions under `/var/lib/rancher/k3s/storage/` on `nvme1n1p2`. There are no static PVs in this repo and nothing points a PVC at `${HOME}/storage/homelab/`; that tree does not exist, and the dedicated 932G disk mounted at `~/storage` is ~1% used. ADR 0002's `homelab-conf`/`homelab-data` split therefore survives only as a naming convention for hostPath mounts (`arr`, `jellyfin`), not for PVCs. Do not repeat the old "PVC pointed at homelab-conf" claim — see `docs/adr/0005-backup-restore.md` "Known gaps".
- **One Helm chart per stack** under `helm/`, each with its own namespace (`homelab-<stack>`). Do not merge unrelated services into a single chart.
- **Prefer `runAsUser: 1000`/`fsGroup: 1000`** (the Compose-era `user: "1000:1000"` equivalent) on LinuxServer.io and similar images when a PVC is bound to `$HOME`-derived host paths. Some images define their own users (Nextcloud `www-data`, Immich postgres) — read chart comments before overriding.
- **No `LoadBalancer`/hostPort exposure for HTTP services.** Traefik (bundled with k3s) + `cert-manager` is the sole ingress path — every HTTP-facing stack ships an `Ingress`/`IngressRoute` in its chart, not a `type: LoadBalancer` Service or hostPort. See `docs/adr/0004-kubernetes-migration.md` for why `nginx-proxy-manager` was retired rather than rehosted.
- **There are no NetworkPolicies.** ADR 0004 and earlier revisions of this file claimed NetworkPolicies gate which namespaces are reachable from public Ingress routes. None has ever existed in this repo — every namespace can reach every other namespace and the node network. Treat it as a known gap (`docs/adr/0005-backup-restore.md`), not as an implemented control.
- **Traefik must keep its `LoadBalancer` Service.** ADR 0004's consequences section says to patch it to `ClusterIP` so it does not compete with `nginx-proxy-manager` for host ports 80/443. That instruction is obsolete and now destructive: NPM is retired and Traefik is the sole public listener, so patching it to `ClusterIP` takes every service offline. Re-read that note as history only.
- **New stacks go through ArgoCD, not manual `helm upgrade`,** once `helm/argocd/apps/00-project.yaml`'s AppProject scope covers them — add a `helm/argocd/apps/<stack>.yaml` Application pointing at `helm/<stack>` and let ArgoCD's sync bring it up. See `helm/argocd/CONTEXT.md`.
- **Public admin UIs are rate-limited, not private — yet.** `argocd`, `headlamp`, `portainer`, the `arr` suite and `openclaw` are internet-facing with app-level auth only, several of them cluster-admin- or host-root-equivalent if breached. Each carries a Traefik `rateLimit` middleware as an interim mitigation. The agreed target state is netbird-only access; see `docs/adr/0005-backup-restore.md` "Public exposure and the netbird migration plan" before adding another public route.
- **Backups: two tools, two destinations.** `helm/velero` backs up all namespaces to S3 weekly (Kubernetes objects + PVC data via Kopia). `helm/backup-local` runs a weekly restic job to the munin external drive (PVC data only, encrypted, works on exFAT). Databases are dumped by Velero pre-backup hooks into a `dumps` PVC rather than copied live — never add a database stack without one. `arr`/`jellyfin` media is hostPath and deliberately not backed up.
- **Image updates arrive as Renovate PRs**, not by manually diffing registries or via a monitor-only tool. `renovate.json` scans `helm/*/values.yaml` for `image.repository`/`image.tag`; minor/patch/digest bumps auto-merge, majors and pinned DB images need manual review. There is no watchtower-equivalent left running in-cluster — Renovate PRs against git are the awareness+remediation mechanism now that ArgoCD makes `git push` the deploy step. `.github/workflows/ci.yml` renders and lints every chart so automerge has a real status check; it does not vet image contents.

## Architecture

### Directory layout

```
~/homelab/
├── README.md              # Human quick start
├── CONTEXT.md             # Domain glossary (this file's companion)
├── CLAUDE.md              # Agent playbook (this file)
├── renovate.json          # Automated image-update PRs against helm/*/values.yaml
├── .github/workflows/      # CI: renders + lints every chart (Renovate automerge gate)
├── docs/adr/               # Architecture decision records
├── scripts/
│   ├── backup/             # status.sh — unified backup progress/stats view
│   ├── env/                # copy_env.sh, apply_env.sh — legacy *.env secrets round-trip
│   └── k8s-secrets/         # copy_secrets.sh, apply_secrets.sh — Sealed Secrets round-trip
└── helm/
    ├── homelab-common/     # Shared library chart (Deployment/Service/PVC/Ingress templates)
    ├── argocd/             # GitOps delivery layer — app-of-apps, see helm/argocd/CONTEXT.md
    ├── velero/             # Cloud backup to S3 (values-only, upstream chart)
    ├── backup-local/       # Weekly restic backup to the munin drive + backup watchdog
    ├── token-auth/         # ForwardAuth bearer-token gate for ollama/hermes public APIs
    ├── cluster-issuers.yaml # cert-manager ClusterIssuers (not chart-packaged, bootstrap-applied)
    ├── headlamp/           # Cluster dashboard UI (upstream chart, values-only, no local Chart.yaml)
    ├── arr/                # Has CONTEXT.md-equivalent knowledge inline in values.yaml comments
    ├── atuin/
    ├── hermes/
    ├── immich/
    ├── jellyfin/
    ├── netbird/
    ├── nextcloud/
    ├── ollama/
    ├── openclaw/
    ├── portainer/
    ├── searxng/
    ├── webui/
    └── yggdrasil/
```

### Storage

| Tree | Holds | Example |
|------|-------|---------|
| `homelab-conf/` | Config, DBs, app state (bound via PVC/local-path-provisioner) | `.../sonarr/config`, `.../nextcloud/app` |
| `homelab-data/` | Bulk user content (bound via PVC/local-path-provisioner) | `.../arr/torrents`, `.../immich/server-data` |

### Secrets bootstrap

Per-stack secrets are committed to git as `SealedSecret` manifests (`helm/<stack>/templates/sealed-*.yaml`), encrypted client-side with `kubeseal` against the in-cluster Sealed Secrets controller's public key — decryptable only by that controller. A stack still mid-migration to sealed secrets may instead use a gitignored `values.secret.yaml` copied from a committed `values.secret.example.yaml`.

For machine/cluster migration or disaster recovery, the human operator uses:
- `scripts/k8s-secrets/copy_secrets.sh` / `apply_secrets.sh` — backs up/restores the Sealed Secrets controller's signing key(s) plus any not-yet-sealed plaintext Secret.
- `scripts/env/copy_env.sh` / `apply_env.sh` — legacy round-trip for any remaining plaintext `*.env`/`values.secret.yaml` files.

Store exported JSON in a vault (e.g. Bitwarden), not in git.

### Stacks overview

| Stack | Notes |
|-------|-------|
| `arr` | Gluetun VPN sidecar; all apps share one pod's network namespace (k8s-native equivalent of Compose's `network_mode: "service:gluetun"`). |
| `atuin` | Self-hosted Atuin shell history sync server + Postgres, so history merges between the desktop and a MacBook. E2E encrypted client-side. Reference pattern for Sealed Secrets adoption. |
| `hermes` | Self-hosted [Hermes Agent](https://github.com/NousResearch/hermes-agent) personal AI assistant; one container multiplexes an OpenAI-compatible API server and a web dashboard. |
| `jellyfin` | Reads media from `homelab-data/arr/media`; Seerr for requests. |
| `immich` | Pinned image versions; postgres + redis + ML container. |
| `netbird` | Trimmed self-hosted VPN control plane (`netbird-server` + `dashboard` only) so a laptop can reach this host's SSH port without exposing it to the internet. |
| `nextcloud` | Bind mounts (now PVCs) need `www-data` ownership — see chart values comments. |
| `ollama` | GPU passthrough via CDI. No auth of its own; public Ingress enforces an API key via a Traefik middleware. |
| `openclaw` | Self-hosted [OpenClaw](https://openclaw.ai) personal AI assistant/agent gateway (email, calendar, chat-app channels). Higher blast radius than most stacks — its gateway token grants agent control. |
| `portainer` | Docker/k8s management UI. |
| `searxng` | Self-hosted SearXNG metasearch engine; shared, key-free web-search backend for `webui`, `openclaw`, and `hermes`. No auth of its own internally; public Ingress gates it with Basic Auth instead of an API key, since it's a browsable UI. |
| `webui` | Open WebUI; `OLLAMA_BASE_URL` points to the `ollama` stack over in-cluster DNS, `SEARXNG_QUERY_URL` to the `searxng` stack for web search. |
| `yggdrasil` | Self-hosted deploy of the user's own [yggdrasil-hq/yggdrasil-core](https://github.com/yggdrasil-hq/yggdrasil-core) (AI-orchestrated dev platform, pre-alpha). GHCR images, not built from source. Shares this same k3s cluster (ADR 0004's rationale #3) — the Orchestrator targets this cluster's API directly. |
| `argocd` | GitOps delivery layer — app-of-apps managing every stack above via `git push` to `main`. See `helm/argocd/CONTEXT.md`. |
| `headlamp` | Cluster dashboard UI, installed from the upstream chart (no local `Chart.yaml`). |
| `velero` | Weekly cloud backup of all namespaces to S3; PVC data via Kopia fs-backup, databases via pre-backup dump hooks. Values-only, upstream chart. See `helm/velero/CONTEXT.md`. |
| `backup-local` | Weekly restic backup of every PVC to the munin external drive, plus the healthchecks.io backup watchdog. Encrypted, and works on the drive's exFAT filesystem. |
| `token-auth` | Tiny ForwardAuth service holding a per-host bearer-token map, gating `ollama` and `hermes`'s public API routes. Replaced an in-routing-rule token match that ArgoCD could never render. |

`nginx-proxy-manager` and `watchtower` were retired during the migration with no direct replacement chart: Traefik + cert-manager took over ingress/TLS, and Renovate PRs took over image-update awareness.

## ADRs

- **ADR 0001** (`docs/adr/0001-detached-homelab-repo.md`): Why homelab is a separate repo from dotfiles.
- **ADR 0002** (`docs/adr/0002-storage-layout.md`): Why homelab-conf and homelab-data are split.
- **ADR 0003** (`docs/adr/0003-per-stack-compose.md`): Why each service group was its own Compose stack (superseded by ADR 0004's per-stack Helm chart).
- **ADR 0004** (`docs/adr/0004-kubernetes-migration.md`): Migration from Docker Compose to k3s/Helm/ArgoCD — the current architecture.
