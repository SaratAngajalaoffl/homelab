{{/*
Generic single-container StatefulSet for stateful backends (databases, etc.), using
volumeClaimTemplates rather than pre-created PVCs so storage is created per-replica.
Usage: {{ include "homelab-common.statefulset" (dict "root" $ "name" "atuin-db" "values" .Values.db) }}

Expected shape of "values": same as homelab-common.deployment, except each
persistence entry becomes a volumeClaimTemplate (no accessMode default change).
*/}}
{{- define "homelab-common.statefulset" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $v := .values -}}
{{- $fullname := include "homelab-common.fullname" (dict "root" $root "name" $name) -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ $fullname }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "homelab-common.labels" (dict "root" $root "name" $name) | nindent 4 }}
spec:
  serviceName: {{ $fullname }}
  replicas: {{ $v.replicas | default 1 }}
  selector:
    matchLabels:
      {{- include "homelab-common.selectorLabels" (dict "root" $root "name" $name) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "homelab-common.labels" (dict "root" $root "name" $name) | nindent 8 }}
    spec:
      {{- with $v.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ $name }}
          image: "{{ $v.image.repository }}:{{ $v.image.tag }}"
          imagePullPolicy: {{ $v.image.pullPolicy | default "IfNotPresent" }}
          {{- if $v.port }}
          ports:
            - containerPort: {{ $v.port }}
          {{- end }}
          {{- if or $v.env $v.envSecretName }}
          {{- if $v.envSecretName }}
          envFrom:
            - secretRef:
                name: {{ $v.envSecretName }}
          {{- end }}
          {{- with $v.env }}
          env:
            {{- range $k, $val := . }}
            - name: {{ $k }}
              value: {{ $val | quote }}
            {{- end }}
          {{- end }}
          {{- end }}
          {{- with $v.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if or $v.persistence $v.extraVolumeMounts }}
          volumeMounts:
            {{- range $v.persistence }}
            - name: {{ .name }}
              mountPath: {{ .mountPath }}
            {{- end }}
            {{- with $v.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          {{- end }}
      {{- with $v.extraVolumes }}
      volumes:
        {{- toYaml . | nindent 8 }}
      {{- end }}
  {{- with $v.persistence }}
  volumeClaimTemplates:
    {{- range . }}
    - metadata:
        name: {{ .name }}
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
  {{- end }}
{{- end -}}
