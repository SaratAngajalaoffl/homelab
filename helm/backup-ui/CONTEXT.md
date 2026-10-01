# backup-ui

Dashboard for Velero (S3) and restic (Munin) backups, plus a form to start a
manual backup of selected categories to S3, Munin, or both.
Source and CI: https://github.com/SaratAngajalaoffl/homelab-backup-ui (this repo
only holds the chart).

## How a manual backup happens
1. You tick categories + targets on https://backups.smugiwara.com and submit.
2. The **web** pod (read-only RBAC + "create ConfigMap") writes a request
   ConfigMap `req-...` in `homelab-backup-ui`.
3. The **dispatcher** pod (own ServiceAccount, no ingress) re-validates it against
   `categories` in values.yaml and creates:
   - S3: a Velero `Backup` `manual-<ts>` in `velero`, location `cloud-manual`
     (`automatic/k3s_backups/manual/`), Secrets excluded, 30-day TTL;
   - Munin: a Job `manual-<ts>` cloned from the suspended `backup-local` CronJob,
     with `BACKUP_NAMESPACES`/`BACKUP_TAGS` injected, into the restic repo
     `<munin>/homelab-backups/manual/` (keeps last 3 per tag set).
   Only one manual run per target at a time; a second request is rejected.
4. The request shows under "Recent requests" with the outcome.

Categories are groups of NAMESPACES: a stack's DB dumps live in its own
namespace, so "databases" can't be split from the app. **A namespace in no
category can't be backed up manually** — add new stacks to `categories`.
The Munin drive must be plugged in; otherwise the Job fails ("not a mount point").

## How a volume restore happens
Enabled when `restore.disks` in values.yaml is non-empty.
1. Pick an active backup (S3 or Munin), one of its volumes (PVC) and a disk.
   The web pod writes a restore ConfigMap `rst-...`.
2. The dispatcher validates it again, creates a NEW PVC on the disk's StorageClass
   (a throwaway `bind-` Job claims it so local-path provisions it), then runs a
   `restore-` Job into the new PV's host directory: restic (clone of the
   `backup-local` template, snapshot tagged `job-<run>`) or Kopia (Velero fs-backup
   snapshot from the BSL bucket).
3. Cutover: ArgoCD auto-sync on the owning Application is paused, the Deployment(s)
   are repointed, the old PVC is labelled `restore-state=orphaned`.
4. In the UI: **Roll back / Switch** (repoint the other way), **Delete** the orphan
   (finalize). If the app is on the new PVC, then put its name in the chart
   (`persistence[].existingClaim`), push, and press **Resume ArgoCD sync**.
`kubectl get pvc -A -l homelab.smugiwara.com/restore-state` lists active/orphaned
volumes. StatefulSet data volumes (databases) are refused: restore those from their
dump PVC. Details: docs/adr/0005-backup-restore.md.

## Access: public, Basic Auth
`backups.smugiwara.com` sits behind Traefik `basicAuth` (Secret
`backup-ui-basic-auth`, a SealedSecret in `templates/sealed-basic-auth.yaml`).
The plaintext credentials were saved once to `~/.backup-ui-password` on the
operator's machine (mode 600) and are not in git. To rotate:

    PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
    HASH=$(printf '%s' "$PW" | openssl passwd -apr1 -stdin)
    kubectl create secret generic backup-ui-basic-auth -n homelab-backup-ui \
      --from-literal=users="admin:${HASH}" --dry-run=client -o yaml \
      | kubeseal --format yaml > helm/backup-ui/templates/sealed-basic-auth.yaml

POSTs also require same-origin (browsers auto-send Basic Auth, so this blocks
cross-site form posts). Target state is still netbird-only
(docs/adr/0005-backup-restore.md).

## Before first sync
`secrets-export` ConfigMap: created by `scripts/k8s-secrets/copy_secrets.sh` on
each export. Until then the key card shows "No vault export recorded".

Private fallback: `kubectl -n homelab-backup-ui port-forward svc/backup-ui 8080:8080`.
