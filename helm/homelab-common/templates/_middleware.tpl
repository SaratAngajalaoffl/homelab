{{/*
Traefik rate-limit Middleware, one per namespace.

Usage: {{ include "homelab-common.rateLimit" (dict "root" $ "rateLimit" .Values.rateLimit) }}

Reference it from an Ingress with the fixed name "ratelimit", matching the
convention searxng's basic-auth middleware already uses:

  ingress:
    annotations:
      traefik.ingress.kubernetes.io/router.middlewares: homelab-<stack>-ratelimit@kubernetescrd

Middlewares are namespaced, and k3s's bundled Traefik ships with
providers.kubernetesCRD.allowCrossNamespace defaulting to false — so each
stack needs its own copy rather than sharing one central object.

WHY this exists: argocd, headlamp, portainer, the *arr suite (qBittorrent in
particular) and openclaw are all publicly reachable with single-factor,
app-level auth only, and several of them are cluster-admin- or host-root-
equivalent if breached. Rate limiting is a mitigation, not a fix — the agreed
target state is to move all of them behind the netbird overlay and drop public
exposure entirely. See docs/adr/0005-backup-restore.md "Public exposure and
the netbird migration plan".

Expected shape of "rateLimit" (all optional):
  average: 20   (requests/sec averaged over the period)
  burst:   40   (max burst above the average)
  period:  1m   (averaging window)
*/}}
{{- define "homelab-common.rateLimit" -}}
{{- $root := .root -}}
{{- $rl := .rateLimit | default dict -}}
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: ratelimit
  namespace: {{ $root.Values.namespace }}
  labels:
    homelab.smugiwara.com/stack: {{ $root.Chart.Name }}
spec:
  rateLimit:
    average: {{ $rl.average | default 20 }}
    burst: {{ $rl.burst | default 40 }}
    period: {{ $rl.period | default "1m" | quote }}
{{- end -}}
