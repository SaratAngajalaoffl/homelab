#!/usr/bin/env bash
# One view of both halves of the backup system, because they live in different
# places and neither is self-announcing:
#
#   cloud  -> Velero CRs in the `velero` namespace (BackupStorageLocation,
#             Schedule, Backup, PodVolumeBackup)
#   local  -> restic, whose only record is the CronJob's pod logs plus the
#             repository on the munin drive
#
# Read-only. Safe to run at any time, including mid-backup — in-progress
# volumes are reported with byte-level progress.
#
# The richer per-backup view is the velero CLI (`velero backup describe <name>
# --details`, `velero backup logs <name>`), which is worth installing:
#   https://velero.io/docs/latest/basic-install/#install-the-cli
# This script deliberately uses plain kubectl so it works without it.
set -euo pipefail

KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/k3s-homelab.yaml}"
if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  echo "error: kubeconfig not found at ${KUBECONFIG_FILE} (set KUBECONFIG_FILE to override)" >&2
  exit 1
fi
export KUBECONFIG="${KUBECONFIG_FILE}"

DRIVE="${DRIVE:-/run/media/mugiwara/munin}"
RESTIC_REPO="${RESTIC_REPO:-${DRIVE}/restic}"

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
dim()  { printf '\033[2m%s\033[0m\n' "$1"; }

# ----------------------------------------------------------------- cloud ----
bold "CLOUD — Velero -> S3"

if ! kubectl get crd backups.velero.io >/dev/null 2>&1; then
  echo "  Velero CRDs are not installed — Velero is not running."
  echo "  See helm/velero/.setup section 2."
else
  kubectl -n velero get backupstoragelocation \
    -o custom-columns='LOCATION:.metadata.name,PHASE:.status.phase,BUCKET:.spec.objectStorage.bucket,PREFIX:.spec.objectStorage.prefix,LAST-CHECKED:.status.lastValidationTime' 2>/dev/null

  echo
  kubectl -n velero get schedule \
    -o custom-columns='SCHEDULE:.metadata.name,CRON:.spec.schedule,STATUS:.status.phase,TTL:.spec.template.ttl,LAST-RUN:.status.lastBackup' 2>/dev/null

  echo
  # Sorted newest-first; .status.expiration is when retention will drop it.
  # Captured to a variable first: piping straight into `head -1` lets head
  # consume the whole buffer, so the following `tail` sees nothing and the
  # table renders as a lone header row.
  BK_TABLE="$(kubectl -n velero get backups --sort-by=.metadata.creationTimestamp \
    -o custom-columns='BACKUP:.metadata.name,PHASE:.status.phase,ERR:.status.errors,WARN:.status.warnings,ITEMS:.status.progress.itemsBackedUp,STARTED:.status.startTimestamp,EXPIRES:.status.expiration' 2>/dev/null || true)"
  if [[ "$(printf '%s\n' "${BK_TABLE}" | wc -l)" -le 1 ]]; then
    echo "  No backups exist in this storage location yet."
    echo "  (Changing the BSL prefix hides backups written under the old one —"
    echo "   Velero's sync controller drops Backup CRs it can no longer find.)"
  else
    printf '%s\n' "${BK_TABLE}" | head -1
    printf '%s\n' "${BK_TABLE}" | tail -n +2 | tac
  fi

  # Per-volume detail only while something is actually running — otherwise this
  # is a wall of Completed rows that says nothing.
  RUNNING="$(kubectl -n velero get backups -o jsonpath='{range .items[?(@.status.phase=="InProgress")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "${RUNNING}" ]]; then
    for b in ${RUNNING}; do
      bold "  in progress: ${b}"
      kubectl -n velero get podvolumebackups -l velero.io/backup-name="${b}" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("items", [])
except Exception:
    sys.exit(0)
rows = []
for i in items:
    st = i.get("status", {}) or {}
    pr = st.get("progress", {}) or {}
    done, total = pr.get("bytesDone", 0), pr.get("totalBytes", 0)
    rows.append((total, done, st.get("phase", "Pending"),
                 i["spec"]["pod"]["namespace"], i["spec"]["volume"]))
rows.sort(reverse=True)
done_n = sum(1 for r in rows if r[2] == "Completed")
print(f"    volumes: {done_n}/{len(rows)} complete")
for total, done, phase, ns, vol in rows[:8]:
    if phase == "Completed" and total == 0:
        continue
    pct = f"{100*done/total:5.1f}%" if total else "    -"
    print(f"    {ns:<22} {vol:<16} {phase:<11} {done/1e9:7.2f}/{total/1e9:7.2f} GB {pct}")
'
    done
  fi
fi

# ----------------------------------------------------------------- local ----
bold "LOCAL — restic -> ${DRIVE}"

if ! mountpoint -q "${DRIVE}" 2>/dev/null; then
  echo "  WARNING: ${DRIVE} is not mounted. The backup CronJob fails closed"
  echo "  rather than writing to the OS disk, so recent runs will have failed."
else
  df -h "${DRIVE}" | awk 'NR==1{printf "  %-12s %8s %8s %8s %6s\n","FILESYSTEM","SIZE","USED","AVAIL","USE%"} NR==2{printf "  %-12s %8s %8s %8s %6s\n",$1,$2,$3,$4,$5}'
  if [[ -d "${RESTIC_REPO}" ]]; then
    echo "  repository:  ${RESTIC_REPO}  ($(du -sh "${RESTIC_REPO}" 2>/dev/null | cut -f1) on disk, deduplicated)"
  else
    echo "  repository:  ${RESTIC_REPO} does not exist yet — no local backup has run."
  fi
fi

echo
kubectl -n homelab-backup-local get cronjob \
  -o custom-columns='CRONJOB:.metadata.name,CRON:.spec.schedule,SUSPENDED:.spec.suspend,LAST-RUN:.status.lastScheduleTime' 2>/dev/null || true

# The snapshot list is only ever printed into the job's own logs, so the most
# recent completed run is the source of truth for what is on the drive.
LAST_JOB="$(kubectl -n homelab-backup-local get jobs \
  --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
  | grep -v watchdog | tail -1 || true)"
if [[ -n "${LAST_JOB}" ]]; then
  echo
  dim "  snapshots (from ${LAST_JOB##*/}):"
  kubectl -n homelab-backup-local logs "${LAST_JOB}" 2>/dev/null \
    | sed -n '/^ID  *Time/,/snapshots$/p' | sed 's/^/    /' || true
fi

# -------------------------------------------------------------- watchdog ----
bold "WATCHDOG — did anyone notice?"
kubectl -n homelab-backup-local get cronjob backup-watchdog \
  -o custom-columns='CRONJOB:.metadata.name,CRON:.spec.schedule,LAST-RUN:.status.lastScheduleTime' 2>/dev/null || true
WJOB="$(kubectl -n homelab-backup-local get jobs --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | grep watchdog | tail -1 || true)"
if [[ -n "${WJOB}" ]]; then
  echo "  last run output:"
  kubectl -n homelab-backup-local logs "${WJOB}" 2>/dev/null | sed 's/^/    /' || true
else
  # LAST-RUN above can still show a timestamp with no Job present: the CronJob
  # records when it fired, but successfulJobsHistoryLimit (or a manual cleanup)
  # may have reaped the Job itself.
  echo "  No watchdog Job is currently retained, so there is no output to show."
  echo "  A LAST-RUN timestamp above means it did fire; the Job has since been"
  echo "  reaped by history limits. healthchecks.io is the durable record."
fi
echo
dim "A silent watchdog is the alert: it pings healthchecks.io ONLY when the"
dim "newest completed Velero backup is under 8 days old. No ping => you get"
dim "an email from healthchecks.io. Verify the check itself at healthchecks.io."
echo
