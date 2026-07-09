{{/*
Build a full image reference from the optional global registry and per-service image config.
Usage: include "eurotransit.imageRef" (list .Values.global.imageRegistry .Values.<service>.image)
*/}}
{{- define "eurotransit.imageRef" -}}
{{- $reg := index . 0 -}}
{{- $img := index . 1 -}}
{{- if $reg -}}{{ $reg }}/{{ $img.repository }}:{{ $img.tag }}{{- else -}}{{ $img.repository }}:{{ $img.tag }}{{- end -}}
{{- end -}}

{{/*
Labels applied to every resource.
*/}}
{{- define "eurotransit.commonLabels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: eurotransit
{{- end -}}

{{/*
preStop hook — brief sleep so kube-proxy and Traefik finish removing this Pod
from the Service endpoints BEFORE SIGTERM reaches the app, so traffic is drained
without dropping in-flight requests. Requires a shell in the container image.
Usage: {{ include "eurotransit.preStop" . | nindent 10 }}
*/}}
{{- define "eurotransit.preStop" -}}
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep {{ .Values.lifecycle.preStopSleepSeconds }}"]
{{- end -}}

{{/*
Standard probes for a Spring Boot service. startup + liveness check the LOCAL
process only (/actuator/health/liveness); readiness (/actuator/health/readiness)
includes downstreams and reports draining during shutdown. Timings from .Values.probes.
Usage: {{ include "eurotransit.probes" . | nindent 10 }}
*/}}
{{- define "eurotransit.probes" -}}
startupProbe:
  httpGet:
    path: /actuator/health/liveness
    port: http
  failureThreshold: {{ .Values.probes.startup.failureThreshold }}
  periodSeconds: {{ .Values.probes.startup.periodSeconds }}
livenessProbe:
  httpGet:
    path: /actuator/health/liveness
    port: http
  periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
  failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
readinessProbe:
  httpGet:
    path: /actuator/health/readiness
    port: http
  periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
  failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
{{- end -}}
