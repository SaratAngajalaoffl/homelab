# ADR 0005: Backup and restore

## Status
Accepted. Supersedes [ADR 0004](0004-kubernetes-migration.md)'s "Backups"
decision (namespaced restic/rsync CronJobs) and its "NetworkPolicies gate
which namespaces may be reached from publicly-exposed Ingress routes" claim.

## Context

ADR 0004 listed backups as the *first* of three reasons to migrate to
Kubernetes at all: "There is no first-class scheduled backup mechanism for
`homelab-conf`/`homelab-data` beyond ad hoc scripting." It then specified
"namespaced CronJobs (restic or rsync-based)" and said this would be built
early, "independent of which stacks have migrated yet, since it's low-risk and
immediately useful."

What actually got built was Velero with two BackupStorageLocations — a cloud S3
bucket, and a local external drive fronted by a MinIO S3 gateway. A review of
the running cluster found that **none of it worked, and no backup had ever been
taken**:

- Velero's CRD install Job was wedged in `Init:ImagePullBackOff` pulling
  `docker.io/bitnami/kubectl:1.36`. Bitnami retired their public Docker Hub
  catalog, so the tag does not exist. No CRDs meant no Velero server, no Kopia
  node-agent, no Schedule — `kubectl get backups.velero.io` returned "the
  server doesn't have a resource type". ArgoCD reported the app `OutOfSync /
  Missing` and nothing acted on it.
- `backup-minio` had never started: `secret "backup-minio-secrets" not found`,
  184 restarts. Its bootstrap step had not been run. `velero-local-credentials`
  did not exist either.
- The `cloud-weekly` Schedule's cron was `0 3 */7 * *`, documented as "every 7
  days". Cron day-of-month `*/7` fires on days 1, 8, 15, 22 and 29, so the
  interval resets each month boundary and drifts against the week.
- Nothing monitored any of this. A backup system that fails silently is
  indistinguishable from one that works, right up until a restore is needed.

Three further problems were structural rather than bootstrap mistakes.

**The drive is exFAT.** MinIO does not support exFAT as a backend — no POSIX
ownership, permissions, or hardlinks. Even with its Secret created, the local
path would not have worked reliably.

**Databases were being copied live.** `defaultVolumesToFsBackup: true` has
Kopia walk each PVC's filesystem with no snapshot and no freeze. For a running
Postgres that yields a torn copy — data files and WAL captured at different
instants — which can fail crash recovery on restore. Four stacks were affected
(immich, atuin, yggdrasil, nextcloud-on-SQLite). Velero's answer is backup
hooks, which are pod annotations, and `homelab-common`'s Deployment/StatefulSet
templates had no annotation support at all, so hooks could not be expressed
through the shared chart even in principle.

**The credential for reading the backups was only inside the cluster.**
`scripts/k8s-secrets/copy_secrets.sh` scanned `homelab-*` namespaces only, so
`velero-cloud-credentials` — the S3 access key — was never exported. Losing the
node would have meant backups in a bucket nobody could authenticate to.

## Decision

**Two tools, one for each destination.**

- **Cloud — Velero.** One `BackupStorageLocation` (`cloud`, S3 `ap-south-1`,
  prefix `automatic/k3s_backups`), one automatic weekly Schedule (`0 3 * * 0`).
  Velero is kept here because it backs up *Kubernetes objects* as well as
  volume data, so a cloud restore can rebuild namespaces, Secrets and PVCs, not
  just files.
- **Local drive — restic** (`helm/backup-local`), a weekly CronJob at 04:00
  Sunday writing an encrypted repository to `/run/media/mugiwara/munin/restic`.

MinIO and the `local` BSL are removed entirely.

### Why restic rather than a Velero BSL

Velero's object-store plugins only speak S3 and it has no filesystem BSL, which
is what forced the MinIO gateway in the first place. restic removes that
indirection and solves three things at once: it works on exFAT unchanged
(content-addressed blobs, no POSIX metadata requirements, so no reformatting a
drive that already holds 83G); it encrypts the repository, which matters
because a Velero backup contains every Secret in the cluster — including the
Sealed Secrets signing key — and this one lives on a portable drive; and it
restores without a cluster, from any machine with the drive and the password.

The cost is asymmetry: the local copy is file-level, not object-level. Rebuild
from cloud; use the drive to get *data* back when the cloud copy is
unavailable or too slow.

### yggdrasil's Postgres: dumped, wiped, reloaded

`postgres:16-alpine -> 18` (commit 1e5994c) landed on a PG16 data directory and
18 refused to start, leaving the database in CrashLoopBackOff and taking
`yggdrasil-api` with it. 18+ stores its cluster in a major-version-specific
subdirectory and hard-errors on a legacy cluster found at the mount root or at
`.../data`, which is a *good* failure: the alternative — emptying the volume
while leaving the mount at `.../data` — makes 18 start happily and write to the
container filesystem, losing everything on restart.

Resolved by dumping with `pg_dumpall`/`pg_dump -Fc` from a temporary PG16 pod,
moving the old cluster aside on-volume as `.pg16-orphan`, letting 18 initialise
into `/var/lib/postgresql/18/docker`, and reloading. Verified table-by-table
against a row-count inventory taken before the migration. `helm/immich` still
runs Postgres 16 and carries a warning comment — it will hit the same wall
whenever its major is bumped.

### Databases are dumped, not copied

`homelab-common` gains `podAnnotations` support on both workload templates.
Each database stack sets a `pre.hook.backup.velero.io` command that dumps to a
dedicated `dumps` PVC before Kopia walks:

- immich, atuin, yggdrasil — `pg_dump -Fc`, written to a temp name and moved
  into place so a partial dump can never masquerade as a good one.
- nextcloud — SQLite, wrapped in `occ maintenance:mode --on/--off`.

The dump is deliberately **not** deleted by a post hook. `backup-local` runs an
hour after Velero and picks up the same fresh dump from the PVC; deleting it
would leave the drive copy with only the torn raw data directory.

Those dump PVCs are standalone PVCs mounted via `extraVolumes`, not
`volumeClaimTemplates` entries: StatefulSet `volumeClaimTemplates` are
immutable, so adding one to a live StatefulSet is rejected by the API server.

`on-error: Fail` on every hook: a database that cannot be dumped should fail
the backup loudly rather than ship one whose database is unrestorable.

### Retention: the last two backups, by two different mechanisms

Both destinations target "keep the last two", but only one can express it
directly. restic has `--keep-last 2`, a true count-based policy, and `forget`
runs only after a *successful* backup — so a failed or skipped run can never
expire what is already on the drive.

Velero has no count-based primitive; `ttl` is the only lever and it is
time-based. At a weekly cadence `336h` (two cycles) holds two backups at steady
state and three briefly after a new one lands. The asymmetry matters: Velero's
copies expire on a clock **whether or not new backups are still succeeding**, so
a silently broken Schedule ends in zero cloud backups rather than two stale
ones. With retention this tight the `backup-watchdog` is load-bearing rather
than a nicety — it is the only thing that distinguishes "backups are current"
from "backups stopped and then evaporated".

The local restic copy is the backstop for exactly that failure, since its two
snapshots persist regardless.

### Monitoring

A `backup-watchdog` CronJob checks daily that the newest *completed* Velero
backup is under 8 days old and pings healthchecks.io only when it is. Failure,
partial failure, or a dead cluster all result in a missed check-in and an
alert. This is a deliberate dead-man's switch rather than push-on-failure,
because the failure this system actually had was silence.

### Scope: media and Ollama models are excluded, by choice

Measured PVC data is 105.8G: immich's photo library is 75.2G of it, Ollama
model weights 22.3G, everything else under 8G. The cloud schedule therefore
excludes `homelab-ollama` — model weights are a re-pullable download, not data,
and they were 21% of every weekly upload. `helm/backup-local` still captures
them, since the external drive has 1.8T free and no per-GB cost.



`arr`'s torrents/media tree and `jellyfin`'s library are `hostPath` mounts, not
PVCs, so Kopia skips them and restic's PVC-root scan does not see them either.
That exclusion is intentional and now accurate in a second sense: the operator
has deleted that data as no longer needed. If a library is rebuilt later it
stays out of scope — it is re-acquirable, and at prior size (~231G) it would
have dominated both the weekly S3 cost and the drive.

## Public exposure and the netbird migration plan

ADR 0004 stated that "NetworkPolicies gate which namespaces may be reached from
publicly-exposed Ingress routes", and CLAUDE.md repeated it as fact. **No
NetworkPolicy has ever existed in this repo.** Every namespace can reach every
other namespace and the node network.

Separately, several publicly-reachable hostnames are cluster-admin- or
host-root-equivalent if breached:

| Host | Blast radius |
|------|--------------|
| `headlamp.smugiwara.com` | ServiceAccount bound to `cluster-admin`, token auth only |
| `argocd.smugiwara.com` | Deploys anything anywhere; single built-in `admin`, no SSO |
| `portainer.smugiwara.com` | Mounts `/var/run/docker.sock` — host root by design |
| `qbittorrent.smugiwara.com` | "Run external program on completion" is RCE by design |
| `sonarr/radarr/prowlarr/homarr` | App-level auth only |
| `openclaw.smugiwara.com` | Gateway token grants agent control; had no ingress gate at all |

**Interim decision:** these stay public, with a Traefik `rateLimit` middleware
(20/s average, 40 burst) in front of each as a credential-stuffing mitigation.
This is explicitly a mitigation, not a fix.

**Target state:** all of the above move behind the netbird overlay and drop
public exposure. netbird already exists in this cluster for exactly this shape
of problem — reaching the host without exposing a port. The migration is:

1. Enrol the devices that actually need these UIs on the netbird mesh.
2. Add a Traefik `ipAllowList` middleware scoped to the netbird CIDR, and
   attach it to each Ingress above in place of (or alongside) the rate limiter.
   cert-manager's HTTP-01 challenge uses its own temporary Ingress, so TLS
   renewal is unaffected.
3. Remove the public DNS records once access is confirmed working.
4. Revisit NetworkPolicies at the same time, so the ADR 0004 claim becomes true
   instead of being deleted.

Not scheduled — recorded so the interim state is understood as interim.

### API endpoints

`ollama` and `hermes` gated their public routes by interpolating a bearer token
directly into a Traefik `IngressRoute` matcher, sourced from a gitignored
`values.secret.yaml`. ArgoCD renders from git and never sees that file, and
neither Application passed `valueFiles`, so both rules rendered as
`^Bearer $` and matched nothing — the endpoints were dead and the auth control
was not running. `selfHeal: true` reverted any manual `helm upgrade -f` on the
next reconcile. The token was also being used as a regex, so a metacharacter in
it would silently change matching semantics, and the comparison was not
constant-time.

Replaced by `helm/token-auth`: a small ForwardAuth service holding a per-host
token map in a real Secret, doing a constant-time compare. Clients are
unchanged — they still send `Authorization: Bearer <token>`. Unknown hosts fail
closed, so adding a route without adding its token cannot leave an open
endpoint.

## Consequences

- `git push` remains the deploy step, but two bootstrap secrets must be created
  by hand before the backup system functions: `backup-local-secrets`
  (restic password) and `backup-watchdog-secrets` (healthchecks.io URL), plus
  `token-auth-secrets` for the API gate. Each stack's `.setup` documents this.
  **The restic password must go to the vault** — losing it makes every snapshot
  on the drive permanently unreadable.
- `copy_secrets.sh` now also exports the `velero` namespace. Re-run it after
  any credential rotation; it is the only thing standing between a lost node
  and unreachable backups.
- A restore has to actually be tested. `helm/velero/.setup` documents a
  namespace-mapped restore of `homelab-atuin` into a scratch namespace as the
  cheapest realistic exercise of the dump-hook path.
- CI (`.github/workflows/ci.yml`) now renders and lints every chart and
  validates that Velero hook commands parse as JSON — a malformed hook is
  accepted silently by Kubernetes and only surfaces as a failed backup.

## Known gaps

- **The cloud IAM policy is prefix-scoped, and the BSL must match.** The policy
  on `loki-homelab-backup-service` grants `s3:ListBucket` only under condition
  `s3:prefix = automatic/*`, and object actions only on `.../automatic/*`. The
  BSL therefore sets `prefix: automatic`; without it Velero lists at the bucket
  root, falls outside the condition, and the location stays `Unavailable`. If
  large backups later fail mid-upload, the likely cause is that the policy omits
  `s3:ListMultipartUploadParts` (and `s3:ListBucketMultipartUploads`), which
  Velero's own reference policy includes and a 75G immich upload will exercise.
- **The chart's CRD job is disabled** (`upgradeCRDs: false`) because it could
  not be made to work: it needs a kubectl image that both ships a shell and
  matches velero's libc, and bitnami's retired catalog was the only thing that
  did. CRDs now come from the chart's `crds/` directory, which Helm does not
  upgrade — so a velero chart bump needs a manual CRD apply. See
  `helm/velero/values.yaml`.
- **No NetworkPolicies.** See above.
- **CI cannot vet image contents.** Renovate still auto-merges digest bumps on
  floating `latest`/`main` tags, and ArgoCD's `selfHeal` deploys them. The CI
  gate proves charts render, nothing more. Pinning real semver tags instead of
  floating ones is the actual fix.
- **PVCs live on the OS disk.** local-path provisions under
  `/var/lib/rancher/k3s/storage` on `nvme1n1p2`, while the dedicated 932G data
  disk at `~/storage` sits at 1% used. Every doc previously claimed PVCs were
  "pointed at" `homelab-conf`/`homelab-data`; nothing ever implemented that and
  there are no static PVs in this repo. Documented as reality rather than
  migrated — see CONTEXT.md's "local-path root" entry and ADR 0002's status
  note.
- **ADR 0004's monitoring stack** (kube-prometheus-stack, Loki, Grafana) remains
  unbuilt. The watchdog covers backups specifically; Velero also exposes
  Prometheus metrics for whenever that stack lands.


## 2026-09-30 — Folders by trigger, manual-only disk, backup dashboard

- **Layout.** S3 backups are split into `automatic/k3s_backups/scheduled/` and
  `.../manual/` (two BackupStorageLocations, `cloud-scheduled` / `cloud-manual`;
  both prefixes must stay under `automatic/` for the IAM policy). Munin holds one
  restic repo at `homelab-backups/manual/`.
- **Disk is manual-only.** The weekly Munin restic job is suspended; the CronJob
  remains as the job template. Rationale: ARR and other bulky data should land on
  disk only when asked for, and the weekly whole-root run produced a 458 GiB
  snapshot that took days.
- **Scope of the scheduled cloud backup.** Excludes Secret objects (the Sealed
  Secrets controller decrypts SealedSecrets into plain Secrets, so backing them up
  puts plaintext in S3), `homelab-arr`, `homelab-ollama`, and the `velero`
  namespace (its own Kopia maintenance-job pods carry emptyDirs that fs-backup
  fails on, turning runs `PartiallyFailed`, which the watchdog does not count).
- **Trigger.** backups.smugiwara.com (helm/backup-ui, source in
  SaratAngajalaoffl/homelab-backup-ui) starts manual backups by category. The
  internet-facing web pod can only create request ConfigMaps; a separate
  dispatcher pod re-validates and creates the Velero Backup / restic Job, so a
  compromised web pod cannot inject exec hooks or host mounts. Whole site is
  behind Basic Auth (Sealed Secret).
- **Reset.** All prior backups (Velero backups + leftover Kopia data under
  `automatic/k3s_backups/`, and the restic repo on Munin) were deleted on this
  date to start clean under the new layout.
- **Known limitations.** Categories are namespace groups (no per-PVC selection).
  The disk list is built from Job history, not the restic repo. Restore is not
  implemented in the UI.
