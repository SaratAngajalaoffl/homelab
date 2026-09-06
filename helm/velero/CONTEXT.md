# velero — cloud backup/restore

Third-party infra (upstream `vmware-tanzu/velero` chart), installed into the
`velero` namespace, same pattern as headlamp/cert-manager/sealed-secrets —
see `helm/argocd/CONTEXT.md`.

## Velero is the cloud half only

One `BackupStorageLocation` (`cloud`, a real S3 bucket in `ap-south-1`), one
automatic weekly Schedule. The local external-drive backup is a separate
stack, `helm/backup-local`, using restic.

This used to be one tool with two BSLs, the local one fronted by a MinIO
gateway (`helm/backup-minio`) because Velero's object-store plugins only
speak S3 and it has no filesystem BSL. That was dropped: the munin drive is
exFAT, which MinIO does not support as a backend (no POSIX ownership,
permissions or hardlinks). restic writes content-addressed blobs in its own
encrypted format, so exFAT is a non-issue and the drive copy is encrypted at
rest — which matters, because these backups contain every Secret in the
cluster including the Sealed Secrets signing key. See
`docs/adr/0005-backup-restore.md`.

## PVCs via fs-backup (Kopia), not snapshots

`configuration.defaultVolumesToFsBackup: true` + `deployNodeAgent: true`
backs up every PVC-backed pod volume by walking the filesystem (Kopia),
because local-path-provisioner has no CSI snapshot support on this
single-node k3s cluster.

## Databases are dumped, not copied live

Kopia walks a live filesystem with no snapshot or freeze, so copying a
running Postgres data directory yields a torn backup — data files and WAL
captured at different instants, which can fail crash recovery on restore.
Every database stack therefore carries Velero **backup hooks**: a
`pre.hook.backup.velero.io` command dumps the database to a dedicated
`dumps` PVC before Kopia walks it, and a `post` hook clears the dump
afterwards. Restores go through the logical dump, not the raw data dir.

This is why `homelab-common`'s Deployment/StatefulSet templates support
`podAnnotations` — Velero hooks are pod annotations, and without that
support they could not be expressed through the shared chart at all.

Covered: `immich`, `atuin`, `yggdrasil` (Postgres, `pg_dump -Fc`), and
`nextcloud` (SQLite, wrapped in `occ maintenance:mode`).

## The CRD job image is pinned deliberately

The chart defaults the CRD job to `docker.io/bitnami/kubectl`, which is no
longer pullable since Bitnami retired their public Docker Hub catalog. That
silently prevented Velero from installing at all. `values.yaml` pins
`registry.k8s.io/kubectl` matching the cluster version — bump it on a k3s
major upgrade. See `.setup` §2.

## Scope: all PVC-backed data except arr's media/torrents

That exclusion falls out for free — `homelab-arr`'s media/torrents tree is a
hostPath mount (see `helm/arr/values.yaml`), not a PVC, and fs-backup only
walks PVC-backed volumes. No explicit exclusion annotation was needed, and
it is a deliberate choice (ADR 0005), not an oversight.

## Credentials

`velero-cloud-credentials` in the `velero` namespace, an AWS-credentials-file
blob under key `cloud`. Created out-of-band per `.setup` — not sealed, not
committed, same never-touch-secrets rule as the rest of this repo. It **is**
included in `scripts/k8s-secrets/copy_secrets.sh`'s export, which it was not
originally: without it a rebuilt cluster cannot authenticate to the bucket
holding its own backups.

## Monitoring

`helm/backup-local` carries a watchdog CronJob that checks the age of the
newest successful Velero backup and pings a healthchecks.io URL; silence
raises the alert. Velero also exposes Prometheus metrics for whenever ADR
0004's monitoring stack gets built.
