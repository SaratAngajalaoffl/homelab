{{/*
One PersistentVolumeClaim per persistence entry, named "<fullname>-<entry.name>".
An entry with `existingClaim` set renders no PVC: the Deployment mounts that claim instead
(see _deployment.tpl). This is how git adopts a volume created by a backups.smugiwara.com restore.
Usage: {{ include "homelab-common.pvcs" (dict "root" $ "name" "atuin-server" "persistence" .Values.server.persistence) }}
*/}}
{{- define "homelab-common.pvcs" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $fullname := include "homelab-common.fullname" (dict "root" $root "name" $name) -}}
{{- range .persistence }}
{{- if not .existingClaim }}
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
{{- end }}
{{- end -}}
{{- end -}}
