{{/*
Generic ClusterIP Service, one port.
Usage: {{ include "homelab-common.service" (dict "root" $ "name" "atuin-server" "port" 8888) }}
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
spec:
  type: ClusterIP
  selector:
    {{- include "homelab-common.selectorLabels" (dict "root" $root "name" $name) | nindent 4 }}
  ports:
    - port: {{ .port }}
      targetPort: {{ .port }}
      protocol: TCP
{{- end -}}
