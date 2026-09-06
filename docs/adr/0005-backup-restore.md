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

- **Cloud — Velero.** One `BackupStorageLocation` (`cloud`, S3 `ap-south-1`),
  one automatic weekly Schedule (`0 3 * * 0`), 30-day TTL, all namespaces.
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

`on-error: Fail` everywhere except yggdrasil — see Known gaps.

### Monitoring

A `backup-watchdog` CronJob checks daily that the newest *completed* Velero
backup is under 8 days old and pings healthchecks.io only when it is. Failure,
partial failure, or a dead cluster all result in a missed check-in and an
alert. This is a deliberate dead-man's switch rather than push-on-failure,
because the failure this system actually had was silence.

### Scope: media is excluded, by choice

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

- **yggdrasil's Postgres is down** and is not fixed here. `postgres:18` landed
  on a data directory written by an earlier major and refuses to start
  (`pg_upgrade` required). `helm/atuin` was corrected to mount the whole
  `/var/lib/postgresql`, which is the layout 18+ expects; `helm/yggdrasil`
  still mounts `/var/lib/postgresql/data`. Changing the mount alone would make
  18 `initdb` a fresh empty cluster over the top, so this needs a deliberate
  operator pass with a backup in hand. Its backup hook is set to
  `on-error: Continue` meanwhile, so a down database does not mark every
  weekly backup PartiallyFailed and destroy the signal from stacks that matter.
  Flip it to `Fail` once it starts.
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
