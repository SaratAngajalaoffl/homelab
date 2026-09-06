# jellyfin Stack Context

## Glossary

**jellyfin-stack** — compose project `jellyfin` in `containers/jellyfin/`. Media server (Jellyfin) + Seerr request manager, sharing one stack.

**k8s migration** — `~/homelab/helm/jellyfin/` holds this stack's Helm chart, converted per `docs/adr/0004-kubernetes-migration.md`. Two Deployments via `helm/homelab-common`: `jellyfin-server` and `seerr`, each with their own Ingress (`jellyfin.smugiwara.com`, `seerr.smugiwara.com`). Live production deployment as of 2026-09-06; Compose stack stopped.

**Media directory is a live `hostPath`, not a PVC** — `/data/media` (229GB, `homelab-data/arr/media`) is mounted straight from the host via `values.yaml`'s `jellyfin.extraVolumes`, deliberately **not** copied into a PVC. The still-Compose `arr` stack (sonarr/radarr/qbittorrent, migrating last due to gluetun's VPN networking) keeps writing new downloads into this exact directory — a PVC snapshot would go stale the moment anything new gets downloaded. `hostPath` keeps this pod reading the same live directory arr's containers write to. **Only valid on a single-node cluster** (true today); revisit if a second node is ever added, and this pod's data view breaks the moment `arr` itself migrates to a k8s-native storage model (PVC) instead of the current host bind mount — that dependency should be resolved when `arr` migrates, not before.

**Data migration — corrected 2026-09-06, the original migration was wrong.** The original pass (documented in this file until now) claimed a verified match based on file *counts* (1028 vs 1031) without checking file *sizes* — and missed that the real `jellyfin.db` (the actual library database: every scanned item, image path, and all watch history) had never been copied at all. The pod had instead been running against a fresh, empty `jellyfin.db` that Jellyfin's own first-boot auto-init created on the target PVC — the same "fresh-install trap" pattern seen with nextcloud/netbird/searxng/webui, just missed here because the byte-size check was skipped. `/config` was 216MB on the running pod vs 621MB on the still-live host directory; the gap was entirely `jellyfin.db` (host: 406MB real library; pod: 464KB fresh stub). **Re-migrated properly**: scaled `jellyfin-server` to 0, ran the standard busybox-hostPath migrate pod, wiped the stale PVC contents (`rm -rf /dst/config/* /dst/cache/*`), copied the real host data in, verified this time via exact file count **and** byte count **and** an `md5sum` of `jellyfin.db` itself (matched: `d8d4cdfa98feea8bb58537d7c3b779ba`, 424738816 bytes both sides), then scaled back to 1. Confirmed post-restart: pod's `jellyfin.db` is 406M, `jellyfin.smugiwara.com/health` → 200.

**Lesson**: matching file *counts* alone is not sufficient verification for a data migration — a fresh-install trap can leave a same-named file in place with totally different (and much smaller) content. Always also compare total byte size, and for any single large/critical file, a checksum.

**seerr's `/app/config`** (8.2MB): 38/38 exact file-count match, not re-checked this pass — this app has no equivalent large single-file-DB risk (small file set, sizes were already consistent with the source), so it wasn't a suspect for this bug.

**No secrets** — neither jellyfin nor seerr use credentialed env vars in this setup (no `SealedSecret` needed for this stack).

**Known gap** — LAN client autodiscovery (UDP broadcast, was host port `31759:7359/udp` in Compose, deliberately bypassing NPM since it's not HTTP) has no k8s equivalent configured yet. `JELLYFIN_PublishedServerUrl` env var (manual server URL) is still set, so manual entry works; only the "auto-find server on LAN" convenience feature is affected.
