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
