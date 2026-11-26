{{/*
Labels for object metadata. Pod templates get only their selector labels: a label added to a
pod template restarts the pod, and Helm's own labels change with every chart version.
*/}}
{{- define "thread.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
