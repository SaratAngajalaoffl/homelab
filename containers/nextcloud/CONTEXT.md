# nextcloud Stack Context

## Glossary

**nextcloud-stack** — compose project `nextcloud-stack` in `containers/nextcloud/`. Single Nextcloud container (SQLite, no separate DB service), config/app dir and user data dir on separate bind mounts.

**k8s migration** — `~/homelab/helm/nextcloud/` holds this stack's Helm chart, converted per `docs/adr/0004-kubernetes-migration.md`. One Deployment (`nextcloud-server`) via `helm/homelab-common`, one Ingress (`cloud.smugiwara.com`). Live production deployment as of 2026-09-06; Compose stack was already stopped before this migration.

**www-data ownership (uid/gid 33)** — the official image runs as `www-data`; the Compose bind mounts were already owned by uid/gid 33 on the host. Replicated via `server.securityContext.fsGroup: 33` in `values.yaml` so PVC-backed data gets the same group ownership Compose had.

**Fresh-install trap caught before data copy** — `helm install` was run first (deliberately, to let the PVCs and Deployment come up cleanly), but Nextcloud's entrypoint auto-runs first-time install against an empty `/var/www/html`, so after the pod went Ready it already had a **fresh, empty** Nextcloud instance with a brand-new `config/config.php`. Caught by checking for `config/config.php` before assuming the deployment was ready for traffic (lesson carried over from atuin's original data-migration gap). Fixed by: scaling the Deployment to 0, spinning up a temporary `busybox` pod mounting both PVCs, wiping the fresh-install content, `tar`-streaming the real Compose data in, `chown -R 33:33` on both PVCs, deleting the busybox pod, and scaling back to 1.

**Data migration (verified)** — `/var/www/html` (app+config, 831MB): 30278/30278 files matched exactly. `/var/www/html/data` (user content, 1.4GB): 1076/1076 files matched, 5/5 md5sum spot-checks passed (including `owncloud.db` and a preview thumbnail). Verified post-restart via `occ status` (`installed: true`, matches the pre-migration Nextcloud version) and externally via `https://cloud.smugiwara.com/status.php` (200, same version string).

**Secrets** — `nextcloud-secrets` (`NEXTCLOUD_ADMIN_PASSWORD`, reusing the existing Compose admin password since the migrated data already has that admin account) is a `SealedSecret` manifest (`helm/nextcloud/templates/sealed-secrets.yaml`), sealed directly from the value in `nextcloud.env` piped straight into `kubeseal` — the plaintext was never displayed and no plaintext `Secret` object was ever created in-cluster.

**No Traefik body-size annotation needed** — Compose/NPM needed `client_max_body_size 0;` (nginx-specific) for large uploads; Traefik has no default request body size limit, so nothing extra was needed in the Ingress.

**In-cluster service name** — Helm release `nextcloud`, component `nextcloud-server` → doubled prefix `nextcloud-nextcloud-server` for the Service/Deployment/PVCs, same convention as every other stack (atuin, immich, portainer, jellyfin).
