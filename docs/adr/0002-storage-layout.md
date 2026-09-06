# ADR 0002: homelab-conf / homelab-data storage split

## Status
Accepted

Partially superseded in practice by [ADR 0005](0005-backup-restore.md): the `homelab-conf`/`homelab-data` split below still describes the `hostPath` mounts (`arr`, `jellyfin`), but **not PVCs**. Every PVC uses the stock `local-path` StorageClass and is provisioned under `/var/lib/rancher/k3s/storage/` on the OS disk; nothing in the repo points a PVC at these paths, and the directories do not currently exist. ADR 0004's claim that PVCs are "pointed at the existing `homelab-conf`/`homelab-data` host paths" was never implemented.

## Context
Docker stacks bind-mount host directories for persistent config and user content. Without a convention, volume paths drift (`~/docker/...`, per-app paths, paths inside the repo) and agents cannot predict where to mount new services.

## Decision
All host-side persistent storage lives under `${HOME}/storage/homelab/` in two trees:

- **`homelab-conf/`** — application configuration, databases, and small state files (Grafana data, *arr configs, NetBird management store).
- **`homelab-data/`** — bulk user-generated content (torrents, media libraries, Immich photos, Nextcloud files).

Compose files reference these via `${HOME}/storage/homelab/homelab-conf/...` and `${HOME}/storage/homelab/homelab-data/...`. Nothing under `~/storage/` is committed to git.

## Alternatives considered
- **Single `homelab/` data tree** — mixes small config with large media; backups and permissions become harder to reason about.
- **Paths relative to the repo** — risks committing runtime data; repo location may differ from clone path.
- **Named Docker volumes** — opaque on disk, harder to inspect, back up, or migrate bind-mounted trees the user already owns.

## Consequences
- New stacks must place volumes in the correct tree; agents document the choice in compose comments when ambiguous.
- Backup strategy can treat `homelab-data/` differently from `homelab-conf/` (frequency, size).
- First-time setup requires `mkdir -p ~/storage/homelab/homelab-conf ~/storage/homelab/homelab-data`.
