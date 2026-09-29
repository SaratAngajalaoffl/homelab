# backup-ui

Read-only dashboard: Velero cloud backups, restic disk runs, watchdog health,
Sealed Secrets key age. Source and CI: https://github.com/SaratAngajalaoffl/homelab-backup-ui (this repo only holds the chart). v1 has no write path.

## Before first sync
1. `secrets-export` ConfigMap: created by `scripts/k8s-secrets/copy_secrets.sh`
   on each export. Until the first export, the key card shows "No vault export
   recorded" (a warning, not a failure).

## Access: public, NO AUTH (temporary)
`backups.smugiwara.com` is a plain Traefik Ingress with cert-manager TLS and no
authentication or rate limit — a deliberate interim choice. It exposes backup
names, times, schedules, the S3 bucket/prefix, and error counts (read-only; no
secrets). Target state is netbird-only, see docs/adr/0005-backup-restore.md.
Do not add trigger/restore actions until auth is in place.

Private fallback without the public route:

    KUBECONFIG=~/.kube/k3s-homelab.yaml kubectl -n homelab-backup-ui port-forward svc/backup-ui 8080:8080
