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
