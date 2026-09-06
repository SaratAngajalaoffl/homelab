{{/*
Single-host Ingress routing to one Service, TLS via cert-manager.
Usage: {{ include "homelab-common.ingress" (dict "root" $ "name" "atuin-server" "ingress" .Values.ingress "port" .Values.server.port) }}

Expected shape of "ingress":
  enabled: true
  host: history.smugiwara.com
  className: traefik
  clusterIssuer: letsencrypt-prod (optional, adds cert-manager.io/cluster-issuer annotation)
  tlsSecretName: atuin-tls (optional; defaults to "<fullname>-tls")
  annotations: {} (optional, merged in as-is)
*/}}
{{- define "homelab-common.ingress" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $ing := .ingress -}}
{{- $fullname := include "homelab-common.fullname" (dict "root" $root "name" $name) -}}
{{- if $ing.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $fullname }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "homelab-common.labels" (dict "root" $root "name" $name) | nindent 4 }}
  annotations:
    {{- if $ing.clusterIssuer }}
    cert-manager.io/cluster-issuer: {{ $ing.clusterIssuer }}
    {{- end }}
    {{- with $ing.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  ingressClassName: {{ $ing.className | default "traefik" }}
  tls:
    - hosts:
        - {{ $ing.host }}
      secretName: {{ $ing.tlsSecretName | default (printf "%s-tls" $fullname) }}
  rules:
    - host: {{ $ing.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $fullname }}
                port:
                  number: {{ .port }}
{{- end }}
{{- end -}}
