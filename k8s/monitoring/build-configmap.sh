#!/usr/bin/env bash
# Re-embed dashboard-thread.json into dashboard-configmap.yaml.
#
# The Grafana sidecar loads dashboards only from ConfigMaps labelled
# grafana_dashboard=1 in namespace monitoring. dashboard-configmap.yaml is
# generated output: edit the JSON, run this, commit both.
set -euo pipefail
cd "$(dirname "$0")"
jq -e . dashboard-thread.json >/dev/null
yq -n '
  .apiVersion = "v1" |
  .kind = "ConfigMap" |
  .metadata.name = "thread-border-routers-dashboard" |
  .metadata.namespace = "monitoring" |
  .metadata.labels.grafana_dashboard = "1" |
  .data."thread-border-routers.json" = load_str("dashboard-thread.json")
' > dashboard-configmap.yaml
# Prove the embedded copy is the file, not a stale copy of it.
diff <(yq -r '.data."thread-border-routers.json"' dashboard-configmap.yaml | jq -S .) \
     <(jq -S . dashboard-thread.json) >/dev/null
echo "dashboard-configmap.yaml re-embedded from dashboard-thread.json"
