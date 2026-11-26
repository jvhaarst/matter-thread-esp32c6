#!/usr/bin/env bash
# Proves that the Helm chart renders the same objects as the kustomize manifests it replaces:
# same kinds, names, namespaces and .spec in full, pod templates included. A difference in a
# pod template would restart every border router and the Matter server when Helm takes over.
#
# Object labels and annotations are left out, because Helm adds its own. Two exceptions are
# compared: the Ingress annotations (they carry the allowlist and the certificate issuer) and
# the PVC annotations apart from helm.sh/resource-policy, which only the chart sets.
#
# Run from anywhere: tests/equivalence.sh. Needs helm, kubectl (for kustomize), yq v4, jq.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

normalise() {
    yq -o=json -I=0 'select(. != null and .kind != "Namespace")' | jq -cS '{
        key: "\(.kind)/\(.metadata.namespace // "-")/\(.metadata.name)",
        value: {
            kind,
            name: .metadata.name,
            namespace: .metadata.namespace,
            spec,
            annotations: (
                if .kind == "Ingress" then (.metadata.annotations // {})
                elif .kind == "PersistentVolumeClaim" then ((.metadata.annotations // {}) | del(."helm.sh/resource-policy"))
                else null end)
        }
    }' | jq -sS 'from_entries'
}

helm template thread thread --namespace thread > "$tmp/chart.yaml"
{ kubectl kustomize k8s/otbr; echo '---'; kubectl kustomize k8s/matter-server; } > "$tmp/kustomize.yaml"

normalise < "$tmp/chart.yaml" > "$tmp/chart.json"
normalise < "$tmp/kustomize.yaml" > "$tmp/kustomize.json"

if ! diff -u --label kustomize --label chart "$tmp/kustomize.json" "$tmp/chart.json"; then
    echo "FAIL: the chart does not render the same objects as k8s/otbr and k8s/matter-server" >&2
    exit 1
fi
echo "PASS: chart and kustomize render the same $(jq 'length' "$tmp/chart.json") objects"
