# webui Stack Context

## Glossary

**webui-stack** — compose project `ai-stack` in `containers/webui/`. Open WebUI chat frontend, talking to `ollama` for inference and `searxng` for web search.

**k8s migration** — `~/homelab/helm/webui/` holds this stack's Helm chart, converted per `docs/adr/0004-kubernetes-migration.md`. One Deployment (`server`) via `helm/homelab-common`, one Ingress (`chat.smugiwara.com`). Live production deployment as of 2026-09-06. Migrated right after `ollama` and (unplanned but necessary) `searxng`, since webui depends on both.

**searxng was migrated first, out of the originally-requested order** — webui depends on searxng for web search, and a k8s pod can't reach a still-Compose container by its Docker network DNS name (different network stack entirely — k8s uses its own CNI, not the Compose `edge` bridge). Since searxng was simple (single container, no secrets beyond a Basic Auth credential, tiny config) and already stopped, it was migrated first rather than building a temporary cross-network bridge. See `containers/searxng/CONTEXT.md`.

**Cross-namespace service DNS, not container names** — Compose's `OLLAMA_BASE_URL=http://ollama:11434` and `SEARXNG_QUERY_URL=http://searxng:8080/...` (same-network container-name resolution) became fully-qualified in-cluster Service DNS names, since `ollama` and `searxng` each live in their own namespace: `http://ollama-server.homelab-ollama.svc.cluster.local:11434` and `http://searxng-server.homelab-searxng.svc.cluster.local:8080/search?q=<query>`. Verified both reachable from inside the webui pod via `curl` (the image doesn't ship `wget`, unlike most Alpine-based images).

**`user: "1000:1000"` replicated via pod `securityContext`** — `runAsUser`/`runAsGroup: 1000` in `values.yaml`, matching Compose's explicit non-root user (the image doesn't have its own default user directive requiring root, unlike ollama/nextcloud).

**Fresh-install trap caught again** (4th time this migration pass — nextcloud, netbird, searxng, now webui) — `helm install` produced a healthy pod, but `/data/webui.db` was a fresh, empty 647KB SQLite DB (no chat history, no users) rather than the real ~4.5MB DB. Fixed with the same recipe: scale to 0, busybox migrate pod, wipe, stream in the real `homelab-conf/webui/data` (25 files, 10.7MB — `webui.db`/`.db-wal`/`.db-shm`, `uploads/`, `cache/`, `vector_db/`), `chown -R 1000:1000`, scale back to 1. Verified via md5sum match on `webui.db` and exact file-count match (25/25) before restarting.

**Secrets** — `WEBUI_SECRET_KEY` (from `webui.env`) is a `SealedSecret` manifest (`helm/webui/templates/sealed-secrets.yaml`), sealed directly from the existing file via `kubeseal` — never displayed, never a plaintext in-cluster Secret.

**Verified externally**: `https://chat.smugiwara.com/` → 200 (a transient 502 right after the post-migration restart was just the app still loading its embedding model at boot, not an error — resolved on its own within ~30s). Confirmed both `OLLAMA_BASE_URL` and `SEARXNG_QUERY_URL` reachable and returning real data from inside the pod.

**Still-Compose consumers of ollama/searxng** — `openclaw` and `hermes` (not migrated yet) still reach the *old* Compose `ollama`/`searxng` container names, which no longer exist (both Compose stacks are stopped). This was already the case before webui's migration (ollama/searxng were stopped when *they* migrated) — not a new break introduced here, but worth remembering: those two stacks are currently missing their search/inference backends until they're migrated too.
