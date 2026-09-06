# velero — backup/restore

Third-party infra (upstream `vmware-tanzu/velero` chart), installed into the
`velero` namespace, same pattern as headlamp/cert-manager/sealed-secrets —
see `helm/argocd/CONTEXT.md`.

## Two BackupStorageLocations, one tool

Velero's object-store plugins only speak S3, so both destinations the user
asked for (cloud + a local external hard drive) are modeled as S3 buckets:

- `cloud` — a real S3 bucket, the automatic weekly target.
- `local` — the `backup-minio` stack (`helm/backup-minio`), a MinIO
  instance whose data dir is a hostPath onto `/run/media/mugiwara/munin`.
  Fronting the drive with MinIO is the only way to give Velero an S3
  endpoint against local disk; there's no plain-filesystem BSL.

## PVCs via fs-backup (Kopia), not snapshots

`configuration.defaultVolumesToFsBackup: true` + `deployNodeAgent: true`
backs up every PVC-backed pod volume by walking the filesystem (Kopia),
because local-path-provisioner has no CSI snapshot support on this
single-node k3s cluster.

## Four jobs, one Schedule

Only the cloud path is automatic (`schedules.cloud-weekly`, `0 3 */7 * *`
against the `cloud` BSL). Local backup and both restores are always
CLI-triggered — see `.setup` for the exact `velero backup create` /
`velero restore create` invocations. Velero has no built-in "run if more
than N days since last backup" primitive; a 7-day cron interval is the
equivalent as long as the node is up at that time.

## Scope: all PVC-backed data except arr's media/torrents

That exclusion falls out for free — `homelab-arr`'s media/torrents tree is
a hostPath mount (see `helm/arr/values.yaml`), not a PVC, and fs-backup only
walks PVC-backed volumes. No explicit exclusion annotation was needed.

## Credentials

Two Secrets (`velero-cloud-credentials`, `velero-local-credentials` in the
`velero` namespace), each an AWS-credentials-file blob under key `cloud`.
Created out-of-band per `.setup` — not sealed, not committed, same
never-touch-secrets rule as the rest of this repo.
