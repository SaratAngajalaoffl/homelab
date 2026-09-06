{{/*
One PersistentVolumeClaim per persistence entry, named "<fullname>-<entry.name>".
Usage: {{ include "homelab-common.pvcs" (dict "root" $ "name" "atuin-server" "persistence" .Values.server.persistence) }}
*/}}
{{- define "homelab-common.pvcs" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $fullname := include "homelab-common.fullname" (dict "root" $root "name" $name) -}}
{{- range .persistence }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ printf "%s-%s" $fullname .name }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "homelab-common.labels" (dict "root" $root "name" $name) | nindent 4 }}
spec:
  accessModes:
    - {{ .accessMode | default "ReadWriteOnce" }}
  {{- if .storageClassName }}
  storageClassName: {{ .storageClassName }}
  {{- end }}
  resources:
    requests:
      storage: {{ .size }}
{{- end -}}
{{- end -}}
