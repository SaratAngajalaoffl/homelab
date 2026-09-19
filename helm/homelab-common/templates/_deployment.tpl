{{/*
Generic single-container Deployment.
Usage: {{ include "homelab-common.deployment" (dict "root" $ "name" "atuin-server" "values" .Values.server) }}

Expected shape of "values":
  image: { repository, tag, pullPolicy (default IfNotPresent) }
  port: <container port>
  command: [] (optional)
  args: [] (optional)
  env: {} (optional, plain key/value env vars)
  envSecretName: "" (optional, Secret providing additional env vars via envFrom)
  persistence: [] (optional, list of { name, mountPath, size, storageClassName, accessMode (default ReadWriteOnce) } -> one PVC + volume per entry, PVC name is "<fullname>-<name>")
  resources: {} (optional)
  securityContext: {} (optional, pod-level)
  extraVolumes: [] (optional, raw k8s volume entries, e.g. emptyDir for /dev/shm)
  extraVolumeMounts: [] (optional, raw k8s volumeMount entries, paired with extraVolumes by name)
  extraPorts: [] (optional, raw k8s containerPort entries, e.g. { containerPort: 3478, protocol: UDP, hostPort: 3478 } for a Compose-style host port publish — single-node only, same caveat as hostPath)
  runtimeClassName: "" (optional, pod-level, e.g. "nvidia" for GPU workloads)
  imagePullSecrets: [] (optional, list of Secret names, e.g. ["ghcr-jeeva"] for a private registry)
  strategy: {} (optional, raw k8s Deployment strategy, e.g. { type: Recreate } — required for any hostPort-binding container on a single-node cluster, since RollingUpdate's surge pod can never schedule while the old pod still holds the port)
  podAnnotations: {} (optional, annotations on the POD template — not the Deployment. Velero's backup hooks are pod annotations, so this is what lets a stack declare a pre-backup database dump; see helm/velero/CONTEXT.md)
*/}}
{{- define "homelab-common.deployment" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $v := .values -}}
{{- $fullname := include "homelab-common.fullname" (dict "root" $root "name" $name) -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $fullname }}
  namespace: {{ $root.Values.namespace }}
  labels:
    {{- include "homelab-common.labels" (dict "root" $root "name" $name) | nindent 4 }}
spec:
  replicas: {{ $v.replicas | default 1 }}
  {{- with $v.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "homelab-common.selectorLabels" (dict "root" $root "name" $name) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "homelab-common.labels" (dict "root" $root "name" $name) | nindent 8 }}
      {{- with $v.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      {{- with $v.imagePullSecrets }}
      imagePullSecrets:
        {{- range . }}
        - name: {{ . }}
        {{- end }}
      {{- end }}
      {{- with $v.runtimeClassName }}
      runtimeClassName: {{ . }}
      {{- end }}
      {{- with $v.securityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ $name }}
          image: "{{ $v.image.repository }}:{{ $v.image.tag }}"
          imagePullPolicy: {{ $v.image.pullPolicy | default "IfNotPresent" }}
          {{- with $v.command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $v.args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if or $v.port $v.extraPorts }}
          ports:
            {{- if $v.port }}
            - containerPort: {{ $v.port }}
            {{- end }}
            {{- with $v.extraPorts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
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
      {{- if or $v.persistence $v.extraVolumes }}
      volumes:
        {{- range $v.persistence }}
        - name: {{ .name }}
          persistentVolumeClaim:
            claimName: {{ printf "%s-%s" $fullname .name }}
        {{- end }}
        {{- with $v.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- end }}
{{- end -}}
