# watchtower

## What it does

Single container that periodically checks every running container's image
against its registry for a newer digest under the same tag, and reports
what's out of date. Runs **monitor-only** (`WATCHTOWER_MONITOR_ONLY=true`) —
it never pulls or restarts anything itself. You get a notification, you
decide when to `--pull always` a stack.

## Why monitor-only, not auto-update

Several stacks pin exact versions on purpose (Immich `v2.6.3`, Atuin
`18.19.0`, Postgres majors across atuin/yggdrasil, immich's vectorchord
postgres image) because a DB image bump can require a manual migration
step or break compatibility with a paired app version. Auto-updating those
out from under yourself is how a homelab breaks at 3am. Everything else
already tracks `:latest`/`:main` and gets refreshed on every
`up-all-stacks.sh` run (`--pull always`), so Watchtower's job here is purely
**awareness**, not remediation.

## Notifications

Uses shoutrrr (`WATCHTOWER_NOTIFICATIONS=shoutrrr` +
`WATCHTOWER_NOTIFICATION_URL`) so it can push to ntfy, Discord, Slack, etc.
without a dedicated stack. Set the URL in `watchtower.env` (see
`.setup`). Without it configured, Watchtower still logs findings to
`docker logs watchtower` on each scheduled run — check there if you haven't
wired up push notifications yet.

## Schedule

`WATCHTOWER_SCHEDULE` is a 6-field cron (seconds first): daily at 08:00.
Adjust in `docker-compose.yml` if you want a different cadence.

## Blast radius

Needs the Docker socket (read-only mount) to inspect running containers and
query registries — same category of access as `portainer`, lower than
`nginx-proxy-manager`'s docker-socket-proxy pattern in `arr`. It cannot
start, stop, or modify containers in monitor-only mode; the socket access
is only used for read/inspect + registry HEAD requests.
