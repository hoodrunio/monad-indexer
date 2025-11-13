{{/*
Expand the name of the chart.
*/}}
{{- define "monad-indexer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncate at 63 chars because some Kubernetes name fields are limited to this (by DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "monad-indexer.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "monad-indexer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "monad-indexer.labels" -}}
helm.sh/chart: {{ include "monad-indexer.chart" . }}
{{ include "monad-indexer.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: monad-indexer
{{- end }}

{{/*
Selector labels
*/}}
{{- define "monad-indexer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "monad-indexer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "monad-indexer.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "monad-indexer.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper image name
*/}}
{{- define "monad-indexer.backend.image" -}}
{{- $registryName := .Values.backend.image.registry -}}
{{- $repositoryName := .Values.backend.image.repository -}}
{{- $tag := .Values.backend.image.tag | default .Chart.AppVersion | toString -}}
{{- if $registryName }}
{{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- else }}
{{- printf "%s:%s" $repositoryName $tag -}}
{{- end }}
{{- end }}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "monad-indexer.imagePullSecrets" -}}
{{- if .Values.global }}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- else if .Values.backend.image.pullSecrets }}
imagePullSecrets:
{{- range .Values.backend.image.pullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Get the PostgreSQL connection string
*/}}
{{- define "monad-indexer.postgresql.connectionString" -}}
{{- if .Values.postgresql.enabled -}}
postgresql://{{ .Values.postgresql.auth.username }}:{{ .Values.postgresql.auth.password }}@{{ include "monad-indexer.fullname" . }}-postgresql-rw:5432/{{ .Values.postgresql.auth.database }}
{{- else -}}
{{- .Values.externalDatabase.url -}}
{{- end -}}
{{- end -}}

{{/*
Get the Redis connection string
*/}}
{{- define "monad-indexer.redis.connectionString" -}}
{{- if .Values.redis.enabled }}
{{- if .Values.redis.auth.enabled }}
redis://:{{ include "monad-indexer.redis.password" . }}@{{ include "monad-indexer.fullname" . }}-redis-master:6379
{{- else }}
redis://{{ include "monad-indexer.fullname" . }}-redis-master:6379
{{- end }}
{{- else }}
{{- .Values.externalRedis.url }}
{{- end }}
{{- end }}

{{/*
Get the Redis password
*/}}
{{- define "monad-indexer.redis.password" -}}
{{- if .Values.redis.auth.existingSecret -}}
{{- printf "%s" .Values.redis.auth.existingSecret -}}
{{- else if .Values.redis.auth.password -}}
{{- .Values.redis.auth.password -}}
{{- else -}}
{{- $secret := (lookup "v1" "Secret" .Release.Namespace (printf "%s-redis" (include "monad-indexer.fullname" .))) -}}
{{- if $secret -}}
{{- index $secret.data "redis-password" | b64dec -}}
{{- else -}}
{{- randAlphaNum 10 -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return true if a secret object should be created for PostgreSQL
*/}}
{{- define "monad-indexer.createPostgresqlSecret" -}}
{{- if and .Values.postgresql.enabled (not .Values.postgresql.auth.existingSecret) }}
    {{- true -}}
{{- end }}
{{- end }}

{{/*
Backend component labels
*/}}
{{- define "monad-indexer.backend.labels" -}}
{{ include "monad-indexer.labels" . }}
app.kubernetes.io/component: backend
{{- end }}

{{/*
Backend selector labels
*/}}
{{- define "monad-indexer.backend.selectorLabels" -}}
{{ include "monad-indexer.selectorLabels" . }}
app.kubernetes.io/component: backend
{{- end }}

{{/*
Get PostgreSQL secret name
*/}}
{{- define "monad-indexer.postgresql.secretName" -}}
{{- if .Values.postgresql.auth.existingSecret -}}
{{- .Values.postgresql.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-postgresql-app" (include "monad-indexer.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Get backend secret name
*/}}
{{- define "monad-indexer.backend.secretName" -}}
{{- if .Values.backend.existingSecret -}}
{{- .Values.backend.existingSecret -}}
{{- else -}}
{{- printf "%s-backend-secret" (include "monad-indexer.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Backend environment variables
*/}}
{{- define "monad-indexer.backend.env" -}}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "monad-indexer.postgresql.secretName" . }}
      key: uri
- name: SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ include "monad-indexer.backend.secretName" . }}
      key: secret-key-base
{{- if .Values.redis.enabled }}
{{- if .Values.redis.auth.enabled }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "monad-indexer.fullname" . }}-redis
      key: redis-password
- name: API_RATE_LIMIT_HAMMER_REDIS_URL
  value: "redis://:$(REDIS_PASSWORD)@$(REDIS_HOST):$(REDIS_PORT)/1"
- name: ACCOUNT_REDIS_URL
  value: "redis://:$(REDIS_PASSWORD)@$(REDIS_HOST):$(REDIS_PORT)"
{{- else }}
- name: API_RATE_LIMIT_HAMMER_REDIS_URL
  value: "redis://$(REDIS_HOST):$(REDIS_PORT)/1"
- name: ACCOUNT_REDIS_URL
  value: "redis://$(REDIS_HOST):$(REDIS_PORT)"
{{- end }}
{{- end }}
{{- if .Values.backend.env }}
{{- range $key, $value := .Values.backend.env }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Microservice labels
*/}}
{{- define "monad-indexer.microservice.labels" -}}
{{ include "monad-indexer.labels" . }}
app.kubernetes.io/component: microservice
{{- end }}

{{/*
Return the appropriate apiVersion for HPA
*/}}
{{- define "monad-indexer.hpa.apiVersion" -}}
{{- if semverCompare ">=1.23-0" .Capabilities.KubeVersion.Version -}}
autoscaling/v2
{{- else -}}
autoscaling/v2beta2
{{- end -}}
{{- end }}

{{/*
Return the appropriate apiVersion for PodDisruptionBudget
*/}}
{{- define "monad-indexer.pdb.apiVersion" -}}
{{- if semverCompare ">=1.21-0" .Capabilities.KubeVersion.Version -}}
policy/v1
{{- else -}}
policy/v1beta1
{{- end -}}
{{- end }}

{{/*
Compile all warnings into a single message.
*/}}
{{- define "monad-indexer.validateValues" -}}
{{- $messages := list -}}
{{- $messages := append $messages (include "monad-indexer.validateValues.database" .) -}}
{{- $messages := append $messages (include "monad-indexer.validateValues.rpc" .) -}}
{{- $messages := without $messages "" -}}
{{- $message := join "\n" $messages -}}
{{- if $message -}}
{{-   printf "\nVALUES VALIDATION:\n%s" $message | fail -}}
{{- end -}}
{{- end -}}

{{/*
Validate database configuration
*/}}
{{- define "monad-indexer.validateValues.database" -}}
{{- if and (not .Values.postgresql.enabled) (not .Values.externalDatabase.url) -}}
monad-indexer: Database
    You must enable PostgreSQL or provide an external database URL.
    Please set postgresql.enabled=true or externalDatabase.url.
{{- end -}}
{{- end -}}

{{/*
Validate RPC configuration
*/}}
{{- define "monad-indexer.validateValues.rpc" -}}
{{- if not .Values.backend.env.ETHEREUM_JSONRPC_HTTP_URL -}}
monad-indexer: RPC Configuration
    You must provide an Ethereum JSON-RPC HTTP URL.
    Please set backend.env.ETHEREUM_JSONRPC_HTTP_URL.
{{- end -}}
{{- end -}}

{{/*
PostgreSQL primary fullname
*/}}
{{- define "monad-indexer.postgresql.primary.fullname" -}}
{{- printf "%s-postgresql-1" (include "monad-indexer.fullname" .) -}}
{{- end -}}

{{/*
PostgreSQL service account name
*/}}
{{- define "monad-indexer.postgresql.serviceAccountName" -}}
{{- if .Values.postgresql.serviceAccount.create -}}
{{- default (printf "%s-postgresql" (include "monad-indexer.fullname" .)) .Values.postgresql.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.postgresql.serviceAccount.name -}}
{{- end -}}
{{- end -}}
