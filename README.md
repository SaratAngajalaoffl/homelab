# homelab

Self-hosted services running on a single-node k3s cluster. Helm charts and ArgoCD app-of-apps manifests live in this repo; runtime data and secrets stay on the host / in-cluster.

## Prerequisites

- A k3s cluster (kubeconfig at `~/.kube/k3s-homelab.yaml`, kept separate from `~/.kube/config`)
- Helm 3, `kubectl`
- Nothing to create for PVCs: they use the stock `local-path` StorageClass and
  are provisioned automatically under `/var/lib/rancher/k3s/storage/`.
- The `arr`/`jellyfin` media tree is a `hostPath`, not a PVC, and does need to
  exist if those stacks are used:

```bash
mkdir -p ~/storage/homelab/homelab-data/arr/media
```

## Quick start

```bash
git clone <repo-url> ~/homelab

# Deploy: git push to main is the deploy step for every stack ArgoCD already
# manages (see helm/argocd/CONTEXT.md) — ArgoCD watches helm/argocd/apps/ and
# reconciles automatically.
git push

# Bootstrapping a brand-new stack before it has an ArgoCD Application:
export KUBECONFIG=~/.kube/k3s-homelab.yaml
helm upgrade --install <stack> ./helm/<stack> -n homelab-<stack> --create-namespace
```

Secrets are gitignored. Never commit plaintext secrets — see below.

## Secrets: export and restore

Per-stack secrets are committed as `SealedSecret` manifests (`helm/<stack>/templates/sealed-*.yaml`), encrypted client-side with `kubeseal` against the in-cluster Sealed Secrets controller's public key — decryptable only by that controller. Two things still need backing up outside git: the controller's own signing key (without it, every committed `SealedSecret` becomes permanently undecryptable), and any secret that hasn't been sealed yet.

### Export — `scripts/k8s-secrets/copy_secrets.sh`

Copies a JSON object to the clipboard with the Sealed Secrets controller's signing key(s) plus any not-yet-sealed plaintext Secret across `homelab-*` **and `velero`**. Store it in a vault (e.g. Bitwarden).

The `velero` namespace is included deliberately: it holds the S3 credential for the bucket the backups live in. While it was excluded, the one thing needed to *read* the backups existed nowhere but the cluster those backups exist to replace.

```bash
./scripts/k8s-secrets/copy_secrets.sh
```

### Restore — `scripts/k8s-secrets/apply_secrets.sh`

Reads that JSON (stdin or clipboard) and restores the controller's key(s) plus any plaintext secrets into the cluster, restarting the controller so it picks up the restored key. Run right after installing the Sealed Secrets controller on a rebuilt cluster, before anything else references it.

```bash
./scripts/k8s-secrets/apply_secrets.sh </path/to/export.json
# or paste JSON into the clipboard, then:
./scripts/k8s-secrets/apply_secrets.sh
```

Both scripts default to `~/.kube/k3s-homelab.yaml` (override with `KUBECONFIG_FILE`) — kept deliberately separate from `~/.kube/config`, which may hold unrelated (work) clusters. **Always verify `kubectl config current-context` before running cluster-affecting commands.**

### Legacy env export/restore — `scripts/env/`

No stack uses `values.secret.yaml` any more — the last two (`ollama`, `hermes`)
moved to `helm/token-auth`. These scripts remain for any leftover plaintext
`*.env`/`values.secret.yaml` files on disk:

```bash
./scripts/env/copy_env.sh
./scripts/env/apply_env.sh </path/to/export.json
```

## Stacks

| Stack | Directory | Description |
|-------|-----------|-------------|
| arr | `helm/arr/` | *arr suite + qBittorrent + FlareSolverr behind Gluetun VPN, one pod |
| atuin | `helm/atuin/` | Self-hosted shell history sync server (Atuin + Postgres) |
| immich | `helm/immich/` | Photo backup (Immich + Postgres + Redis) |
| jellyfin | `helm/jellyfin/` | Media server + Seerr request manager |
| netbird | `helm/netbird/` | Self-hosted VPN control plane for SSH access without a public port |
| nextcloud | `helm/nextcloud/` | File sync and collaboration |
| ollama | `helm/ollama/` | Ollama server with GPU passthrough; public endpoint gated by `token-auth` |
| openclaw | `helm/openclaw/` | Self-hosted personal AI assistant/agent gateway |
| hermes | `helm/hermes/` | Self-hosted Hermes Agent personal AI assistant |
| portainer | `helm/portainer/` | Docker/k8s management UI |
| searxng | `helm/searxng/` | Self-hosted metasearch, shared backend for webui/openclaw/hermes |
| webui | `helm/webui/` | Open WebUI (connects to the ollama stack) |
| yggdrasil | `helm/yggdrasil/` | Self-hosted AI-orchestrated dev platform, shares this cluster |
| argocd | `helm/argocd/` | GitOps delivery layer — app-of-apps managing every stack above |
| headlamp | `helm/headlamp/` | Cluster dashboard UI (upstream chart) |
| velero | `helm/velero/` | Weekly cloud backup of all namespaces to S3 (upstream chart) |
| backup-local | `helm/backup-local/` | Weekly restic backup to the munin external drive, plus the backup watchdog |
| token-auth | `helm/token-auth/` | Bearer-token ForwardAuth gate for the ollama/hermes public APIs |

`nginx-proxy-manager` and `watchtower` were retired during the k3s migration (see `docs/adr/0004-kubernetes-migration.md`): Traefik + cert-manager now handle ingress/TLS, and Renovate PRs handle image-update awareness.

## Backups

Two tools, two destinations — see [`docs/adr/0005-backup-restore.md`](docs/adr/0005-backup-restore.md).

| | Tool | Schedule | Contents |
|---|---|---|---|
| Cloud | Velero → S3 | Sundays 03:00, automatic | All namespaces: k8s objects + PVC data (Kopia) |
| Local | restic → munin drive | Sundays 04:00, automatic | PVC data only, encrypted |

Databases are dumped by Velero pre-backup hooks into a `dumps` PVC rather than
copied live, because a filesystem walk of a running Postgres produces a torn
copy. `arr`/`jellyfin` media is a `hostPath` and is deliberately not backed up.

Three secrets must be created by hand before any of this works — see each
stack's `.setup`. **The restic password belongs in your vault:** lose it and
every snapshot on the drive is permanently unreadable.

Restores are always manual. `helm/velero/.setup` documents a scratch-namespace
restore test; run it at least once rather than assuming.

```bash
velero backup get                                     # what exists
velero restore create --from-backup <name>            # cloud restore
```

## Storage layout

| Path | Purpose |
|------|---------|
| `~/homelab/` | This repo — Helm charts, ArgoCD manifests, scripts |
| `/var/lib/rancher/k3s/storage/` | **Where every PVC actually lives** — dynamically provisioned by local-path on the OS disk |
| `~/storage/homelab/homelab-data/arr/` | The `arr`/`jellyfin` media tree, a `hostPath` (currently empty) |

> ADR 0002's `homelab-conf`/`homelab-data` split describes the `hostPath`
> mounts only. It was never implemented for PVCs — nothing points a PVC at
> those paths, and the 932G disk at `~/storage` is nearly empty while all PVC
> data sits on the OS disk. See ADR 0005's "Known gaps".

## Agent docs

AI-oriented documentation lives alongside the repo:

- [`CONTEXT.md`](CONTEXT.md) — domain glossary
- [`CLAUDE.md`](CLAUDE.md) — conventions and commands for agents
- [`docs/adr/`](docs/adr/) — architecture decision records
- [`helm/argocd/CONTEXT.md`](helm/argocd/CONTEXT.md) — GitOps delivery layer details
