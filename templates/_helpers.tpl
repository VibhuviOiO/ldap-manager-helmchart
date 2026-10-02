{{- define "ldap-manager.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ldap-manager.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ldap-manager.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ldap-manager.labels" -}}
helm.sh/chart: {{ include "ldap-manager.chart" . }}
{{ include "ldap-manager.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "ldap-manager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ldap-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Selector for the application pods only, so a helm test or Job pod carrying
     the plain selector labels cannot be published as a Service endpoint. */}}
{{- define "ldap-manager.appSelectorLabels" -}}
{{ include "ldap-manager.selectorLabels" . }}
app.kubernetes.io/component: app
{{- end -}}

{{- define "ldap-manager.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ldap-manager.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "ldap-manager.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{- define "ldap-manager.dataClaimName" -}}
{{- printf "%s-data" (include "ldap-manager.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ldap-manager.secretsClaimName" -}}
{{- printf "%s-secrets" (include "ldap-manager.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ldap-manager.cacheClaimName" -}}
{{- printf "%s-cache" (include "ldap-manager.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ldap-manager.configMapName" -}}
{{- if .Values.config.existingConfigMap -}}
{{- tpl .Values.config.existingConfigMap . -}}
{{- else -}}
{{- printf "%s-config" (include "ldap-manager.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Name of the Secret used for envFrom/volume mounts, or "" for none. */}}
{{- define "ldap-manager.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- tpl .Values.secrets.existingSecret . -}}
{{- else if .Values.secrets.create -}}
{{- printf "%s-secrets" (include "ldap-manager.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Path the app reads, which is what LDAP_MANAGER_CONFIG is set to. */}}
{{- define "ldap-manager.configFile" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.config.mountPath) .Values.config.key -}}
{{- end -}}

{{/*
config.yml content.

`config.content` is a verbatim escape hatch (rendered through tpl); otherwise
the structured auth/clusters values are rendered. Both produce the same file the
app reads at $LDAP_MANAGER_CONFIG.
*/}}
{{- define "ldap-manager.configYml" -}}
{{- if .Values.config.content -}}
{{- tpl .Values.config.content . -}}
{{- else -}}
auth:
  mode: {{ .Values.config.auth.mode | quote }}
  default_role: {{ .Values.config.auth.defaultRole | quote }}
  session:
    lifetime_hours: {{ .Values.config.auth.sessionLifetimeHours }}
{{- with .Values.config.auth.ldap }}
  ldap:
{{ toYaml . | indent 4 }}
{{- end }}
clusters:
{{- if .Values.config.clusters }}
{{ toYaml .Values.config.clusters | indent 2 }}
{{- else }}
  []
{{- end }}
{{- if .Values.config.extra }}
{{ .Values.config.extra | trim }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Chart-created PVCs that use ReadWriteOnce. Every replica mounts the same claim,
so more than one replica with an RWO volume is a deadlock, not a warning.
existingClaim is skipped: the operator may have supplied an RWX-backed claim.
*/}}
{{- define "ldap-manager.rwoPvcs" -}}
{{- $out := list -}}
{{- range $key := list "data" "secrets" "cache" -}}
{{- $p := index $.Values.persistence $key -}}
{{- if and $p.enabled (not $p.existingClaim) (has "ReadWriteOnce" $p.accessModes) -}}
{{- $out = append $out (printf "persistence.%s" $key) -}}
{{- end -}}
{{- end -}}
{{- join ", " $out -}}
{{- end -}}

{{/* Sessions are HMAC-signed. Without LDAP_MANAGER_SECRET_KEY the key lives in
     /app/.secrets, so every replica needs the same RWX volume. */}}
{{- define "ldap-manager.replicaGuard" -}}
{{- if gt (int .Values.replicaCount) 1 -}}
{{- $rwo := include "ldap-manager.rwoPvcs" . -}}
{{- if $rwo -}}
{{- fail (printf "replicaCount=%d mounts one ReadWriteOnce PVC into every pod (%s). Use ReadWriteMany with a matching StorageClass, or set replicaCount=1, or point persistence.*.existingClaim at an RWX-backed claim." (int .Values.replicaCount) $rwo) -}}
{{- end -}}
{{- $envKey := and .Values.secrets.create (hasKey .Values.secrets.env "LDAP_MANAGER_SECRET_KEY") -}}
{{- if not (or .Values.secrets.existingSecret $envKey) -}}
{{- $sharedSecrets := or .Values.persistence.secrets.existingClaim .Values.persistence.secrets.enabled -}}
{{- if not $sharedSecrets -}}
{{- fail "replicaCount > 1 with persistence.secrets disabled gives each pod its own /app/.secrets and therefore its own session key, so a session signed by one replica is rejected by the next. Set LDAP_MANAGER_SECRET_KEY in secrets.env (or secrets.existingSecret), or persist and share /app/.secrets (ReadWriteMany)." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
