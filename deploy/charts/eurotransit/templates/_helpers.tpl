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

{{- /*
Topology spread for an app Deployment (ADR 0023): spread replicas across nodes
and zones so "N replicas" actually means N failure domains — 2 pods on one node
are still one outage from zero.

The per-node (hostname) constraint hardness is a PARAMETER:
  - hard=true  -> DoNotSchedule: replicas MUST land on different nodes. Used for
    the critical money-path services (orders/inventory/payments) after CE-3's
    prerequisite check found the soft version had co-located both `orders`
    replicas on one node — soft spreading proved not enough, exactly the
    question the original comment left to CE-3 to answer.
  - hard=false -> ScheduleAnyway (soft). Kept for catalog (read-only AP cache)
    and notifications (graceful-degradation, 1 replica): a hard rule would risk
    Pending for no availability gain on those.

The ZONE constraint stays SOFT deliberately: this cluster is single-zone (all
nodes in zone "0"), so a hard zone rule with maxSkew 1 would be permanently
unsatisfiable for any 2-replica service — Pending forever. Left as
ScheduleAnyway so it becomes a real constraint if a multi-zone pool is ever
added, without breaking the single-zone present.

Usage: {{ include "eurotransit.topologySpread" (dict "name" "eurotransit-orders" "instance" .Release.Name "hard" true) }}
*/ -}}
{{- define "eurotransit.topologySpread" -}}
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: {{ if .hard }}DoNotSchedule{{ else }}ScheduleAnyway{{ end }}
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: {{ .name }}
        app.kubernetes.io/instance: {{ .instance }}
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: {{ .name }}
        app.kubernetes.io/instance: {{ .instance }}
{{- end }}

{{- /*
Pod-level security context (hardening C1): enforces non-root UID and the
RuntimeDefault seccomp profile. Applied at spec.securityContext on every
Deployment. The JVM images run as UID 10001 (created in the Dockerfile);
nginx runs as the stock nginx user (UID 101).
Usage: {{ include "eurotransit.podSecurityContext" . | nindent 6 }}
*/ -}}
{{- define "eurotransit.podSecurityContext" -}}
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- /*
Container-level security context (hardening C1): least-privilege defaults.
Drop ALL Linux capabilities, deny privilege escalation, and make the root
filesystem read-only. Services that need a writable directory (e.g. /tmp
for the JVM) must mount an emptyDir separately.
Usage: {{ include "eurotransit.containerSecurityContext" . | nindent 10 }}
*/ -}}
{{- define "eurotransit.containerSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
{{- end -}}

{{- /*
Kafka SASL env vars (hardening H1): Spring Boot properties for SCRAM-SHA-512
authentication against the Strimzi broker. The JAAS config string uses
Kubernetes $(VAR) substitution to inject the password from the KafkaUser secret.
Usage: {{ include "eurotransit.kafkaSaslEnv" "secret-name" | nindent 12 }}
*/ -}}
{{- define "eurotransit.kafkaSaslEnv" -}}
- name: SPRING_KAFKA_PROPERTIES_SECURITY_PROTOCOL
  value: "SASL_PLAINTEXT"
- name: SPRING_KAFKA_PROPERTIES_SASL_MECHANISM
  value: "SCRAM-SHA-512"
- name: KAFKA_USER
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: username
- name: KAFKA_PASS
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: password
- name: SPRING_KAFKA_PROPERTIES_SASL_JAAS_CONFIG
  value: 'org.apache.kafka.common.security.scram.ScramLoginModule required username="$(KAFKA_USER)" password="$(KAFKA_PASS)";'
{{- end -}}
