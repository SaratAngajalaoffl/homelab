{{/*
Generic ClusterIP Service, one port.
Usage: {{ include "homelab-common.service" (dict "root" $ "name" "atuin-server" "port" 8888) }}
Optional "annotations" dict, e.g. to make Traefik speak h2c/http2 to this
backend: (dict "root" $ "name" "netbird-server" "port" 80 "annotations" (dict "traefik.ingress.kubernetes.io/service.serversscheme" "h2c"))
*/}}
{{- define "homelab-common.service" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $fullname := include "homelab-common.fullname" (dict "root" $root "name" $name) -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $fullname }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "homelab-common.labels" (dict "root" $root "name" $name) | nindent 4 }}
  {{- with .annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: ClusterIP
  selector:
    {{- include "homelab-common.selectorLabels" (dict "root" $root "name" $name) | nindent 4 }}
  ports:
    - port: {{ .port }}
      targetPort: {{ .port }}
      protocol: TCP
{{- end -}}
