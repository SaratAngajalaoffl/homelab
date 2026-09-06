# portainer Stack Context

## Glossary

**portainer-stack** — compose project `portainer-stack` in `containers/portainer/`. Docker management UI.

**k8s migration** — `~/homelab/helm/portainer/` holds this stack's Helm chart, converted per `docs/adr/0004-kubernetes-migration.md`. Single Deployment via `helm/homelab-common`. Live production deployment as of 2026-09-06; Compose stack stopped.

**Local docker.sock access preserved** — the user explicitly wanted to keep monitoring containers running directly on this host (outside k8s) through Portainer, not just k8s workloads. `values.yaml`'s `server.extraVolumes`/`extraVolumeMounts` mounts `/var/run/docker.sock` into the pod via a `hostPath` volume (`type: Socket`, which kubelet validates at pod-admission time — the pod fails to start if the path isn't actually a socket). Same trust model as the Compose bind mount: Portainer already had root-equivalent host access before this migration, so this is parity, not a new exposure. **Only works because this is a single-node cluster** — if a second node is ever added, this pod must stay pinned to the node that owns `/var/run/docker.sock` (add a `nodeSelector`/`nodeName`, not yet configured since it's currently moot).

**Data migration** — `/data` (Portainer's own BoltDB state — environments, settings, users) is tiny (2.3MB, 8 files). The `portainer/portainer-ce` image has no shell or `tar` (distroless-style), so the usual `tar | kubectl exec` copy approach doesn't work directly against the target pod. Worked around by: scaling the Deployment to 0, spinning up a temporary `busybox` pod mounting the same PVC, copying via that pod, deleting it, then scaling back to 1. Verified 8/8 files copied; startup logs confirmed it loaded the real migrated `portainer.db` (`endpoint_id=3` from the pre-existing local Docker environment), not a fresh install.

**Ingress** — `portainer.smugiwara.com` → port 9000 (the HTTP UI port; 9443/HTTPS and 8000/edge-tunnel ports exist in the image but aren't exposed, matching the original Compose setup which also only used 9000).
