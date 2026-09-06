{{/*
Fully-qualified name for a workload: <release>-<name>, or just <release> if name == release.
Usage: {{ include "homelab-common.fullname" (dict "root" $ "name" "atuin-server") }}
*/}}
{{- define "homelab-common.fullname" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- if eq $name $root.Release.Name -}}
{{- $root.Release.Name -}}
{{- else -}}
{{- printf "%s-%s" $root.Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Standard labels every object gets. Usage: {{ include "homelab-common.labels" (dict "root" $ "name" "atuin-server") }}
*/}}
{{- define "homelab-common.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
homelab.smugiwara.com/stack: {{ .root.Chart.Name }}
{{- end -}}

{{/*
Selector labels (subset of the above, stable across upgrades — must never change once a workload exists).
*/}}
{{- define "homelab-common.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}
