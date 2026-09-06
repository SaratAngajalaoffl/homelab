# argocd — GitOps delivery layer

## What this is

Third-party infra (upstream `argo/argo-cd` Helm chart, `helm/argocd/values.yaml`), installed into the `argocd` namespace per `docs/adr/0004-kubernetes-migration.md`'s "GitOps delivery (ArgoCD)" decision. `git push` to `main` is now the deploy step for every migrated stack — `helm upgrade --install` is no longer how any of them are updated.

Live at `https://argocd.smugiwara.com` (Traefik + cert-manager Ingress, `server.insecure: true` in values so TLS terminates at the edge like every other Ingress in this cluster, instead of ArgoCD's own SSL passthrough).

## Structure — app-of-apps

- `helm/argocd/root-app.yaml` — the one Application applied by hand (`kubectl apply -f helm/argocd/root-app.yaml`, plus `apps/00-project.yaml`). Watches `helm/argocd/apps/` (recursive directory source) and reconciles everything in it — the AppProject and one child `Application` per stack. Editing anything under `apps/` and pushing to `main` is now how you add/change what ArgoCD manages; no further manual `kubectl apply` should be needed after the two-file bootstrap.
- `helm/argocd/apps/00-project.yaml` — the `homelab` AppProject. Scopes source repos (this repo, the headlamp chart repo, and the vmware-tanzu chart repo for velero), allowed destinations (`homelab-*` namespaces + `headlamp` + `velero`), and whitelisted resource kinds. **`clusterResourceWhitelist` had to be widened to include `rbac.authorization.k8s.io/ClusterRoleBinding`** — headlamp's pre-existing `headlamp-admin` ClusterRoleBinding (binds its ServiceAccount to `cluster-admin`, unchanged from before ArgoCD) isn't a namespaced resource and was rejected by the default project scope until added.
- `helm/argocd/apps/<stack>.yaml` — one `Application` per already-migrated stack, `source.path: helm/<stack>`, `destination.namespace: homelab-<stack>`, `syncPolicy.automated: {prune: true, selfHeal: true}`. Covers every stack that had a working `helm/<stack>/Chart.yaml` at the time ArgoCD was introduced: arr, atuin, hermes, immich, jellyfin, netbird, nextcloud, ollama, openclaw, portainer, searxng, webui, **and yggdrasil** — the ADR's own text says to leave yggdrasil to its own Orchestrator, but the user explicitly asked for it included when this was set up, so it is. Added since: `backup-local` and `token-auth` (both ordinary single-source Applications), and `velero` (multi-source, see below). `backup-minio` was removed — see `docs/adr/0005-backup-restore.md`.
- `helm/argocd/apps/velero.yaml` — same multi-source shape as headlamp, for the same reason: velero is a values-only chart with no local `Chart.yaml`, installed from `https://vmware-tanzu.github.io/helm-charts`. **A `Synced` status here does not mean velero works** — it was `OutOfSync / Missing` for its entire life because the upstream chart's CRD job could not pull its image, and nothing acted on that. See `helm/velero/.setup` §2.
- `helm/argocd/apps/headlamp.yaml` — the one exception: headlamp has no local `Chart.yaml` (see `helm/headlamp/values.yaml`, installed straight from the upstream `headlamp/headlamp` chart). This needed a **multi-source Application** (`spec.sources`, not `spec.source`): one source pulls the upstream chart by `chart:`/`targetRevision:`, the other is this git repo aliased `ref: values` so `helm.valueFiles: ["$values/helm/headlamp/values.yaml"]` can reach into it.

## Adopting already-live stacks — no downtime, no data touched

Every stack was already running via `helm upgrade --install` before ArgoCD existed. Adoption was just: commit the chart directories that had never actually been committed (see below), apply the two bootstrap manifests, and let ArgoCD's first sync reconcile — since the committed values already matched exactly what was already deployed, every stack synced clean on the first try with zero resource changes. The stale `helm.sh/release.v1` Secret history from the old `helm upgrade --install` releases is left in place in each namespace (harmless, just no longer touched) rather than run through `helm uninstall`, which would risk deleting live resources.

## Git access — read-only deploy key, not the operator's own SSH key

This is a **private** GitHub repo. ArgoCD's repo-server needs its own git credential — it cannot use the operator's local `~/.ssh` agent. Fixed by generating a fresh, dedicated `ed25519` keypair, adding the public half as a **read-only Deploy Key** on the repo (`gh repo deploy-key add`, approved explicitly before running since it modifies GitHub repo settings), then registering the private key in-cluster as a `repo-creds`-labeled Secret (`homelab-repo-creds` in the `argocd` namespace) via the same "never display the plaintext, generate scratch file, delete it after loading" pattern used for Sealed Secrets elsewhere. The private key file was deleted from disk immediately after being loaded into the cluster Secret — it exists nowhere outside that one Secret and GitHub's own deploy-key record.

## headlamp chart repo also needed explicit registration

Even with `chart:`/`targetRevision:` set on the Application's helm source, the repo-server hung and timed out (`git_ms=60001` in its logs) trying to fetch `https://kubernetes-sigs.github.io/headlamp/index.yaml` — it wasn't registered as a known Helm repository (being listed in the AppProject's `sourceRepos` alone wasn't enough). Fixed by registering it explicitly as a `type: helm` Repository Secret (`headlamp-helm-repo`, same secret-labeling pattern as the git repo-creds secret, no credentials needed since it's a public chart repo).

## Admin login

Username `admin`, password is ArgoCD's own auto-generated `argocd-initial-admin-secret` (in the `argocd` namespace) — not sealed or committed anywhere, since it's generated in-cluster on first install with no plaintext source of truth to seal ahead of time (same reasoning as headlamp's token-based login). Read once via `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`, then rotate/delete per ArgoCD's own getting-started docs.

## Known gap / not yet done

- `cluster-issuers.yaml` (the two `ClusterIssuer`s) and the third-party infra charts installed before ArgoCD existed (cert-manager, sealed-secrets-controller, nvidia-device-plugin, Traefik itself) are **not** ArgoCD-managed — they stay bootstrap/manual `helm`/`kubectl apply`, same as ArgoCD's own installation. Only the stacks listed above are in scope.
- No ArgoCD self-management (an Application managing its own Helm release) — left as manually-upgraded infra for now, consistent with how cert-manager/sealed-secrets/headlamp are treated (upstream infra, not a "stack").
- Admin auth is still the single built-in `admin` account — no SSO/OIDC configured, same single-user caveat as headlamp. ArgoCD's Ingress now carries a `rateLimit` middleware (delivered through the upstream chart's `extraObjects`) as an interim mitigation; the agreed target state is netbird-only access. See `docs/adr/0005-backup-restore.md` "Public exposure and the netbird migration plan".
- ArgoCD reports app health but nobody watches it. Two apps were sitting `Missing`/`Degraded` for their whole existence. The backup watchdog in `helm/backup-local` covers the backup path specifically; general app-health alerting still needs ADR 0004's unbuilt monitoring stack.
