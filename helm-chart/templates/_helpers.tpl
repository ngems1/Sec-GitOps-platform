{{- /*
Guardrails added to every Deployment's pod spec (when guardrails.enabled):
- priorityClassName: the namespace's PriorityClass (prod outranks dev, so on a
  full cluster prod pods are scheduled first and can preempt dev pods);
- topologySpreadConstraints: spread a service's pods across availability zones
  and nodes. "ScheduleAnyway" = a preference, never a reason to stay Pending.
Usage: {{- include "boutique.podGuardrails" (dict "root" $ "app" .Values.frontend.name) | nindent 6 }}
*/ -}}
{{- define "boutique.podGuardrails" -}}
{{- if .root.Values.guardrails.enabled }}
priorityClassName: {{ .root.Release.Namespace }}
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: ScheduleAnyway
  labelSelector:
    matchLabels:
      app: {{ .app }}
- maxSkew: 1
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: ScheduleAnyway
  labelSelector:
    matchLabels:
      app: {{ .app }}
{{- end }}
{{- end }}

{{- /*
Tracing env (ADR 0010) for the services that already have OpenTelemetry code: frontend,
checkoutservice, productcatalogservice, currencyservice, paymentservice, recommendationservice,
emailservice. Only when tracing.enabled (dev): they then export OTLP gRPC to the collector in
"monitoring". deployment.environment is the namespace without "boutique-" (dev / prod).
Usage (renders nothing at all when off):
  {{- with (include "boutique.tracingEnv" (dict "root" $ "name" .Values.frontend.name)) }}{{ . | nindent 10 }}{{ end }}
*/ -}}
{{- define "boutique.tracingEnv" -}}
{{- if .root.Values.tracing.enabled -}}
- name: ENABLE_TRACING
  value: "1"
- name: COLLECTOR_SERVICE_ADDR
  value: {{ required "tracing.collectorAddr is required when tracing.enabled" .root.Values.tracing.collectorAddr | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ .name | quote }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ printf "deployment.environment=%s,service.namespace=boutique" (trimPrefix "boutique-" .root.Release.Namespace) | quote }}
{{- end }}
{{- end }}
