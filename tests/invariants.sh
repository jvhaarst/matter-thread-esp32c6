#!/usr/bin/env bash
# Properties of the rendered chart that must hold whatever the values are. Each one guards
# something that would hurt if it broke: an immutable selector, the radio a border router
# opens, the Matter fabric's volume, digest pinning, and the per-router image override.
#
# Run from anywhere: tests/invariants.sh. Needs helm, yq v4, jq.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

render() { helm template thread thread --namespace thread "$@" | yq -o=json -I=0 'select(. != null)' | jq -s .; }
render > "$tmp/default.json"
q() { jq -r "$1" "$tmp/default.json"; }

# The objects Helm takes over keep their names; the chart never owns the namespace.
want="matter-server otbr-raspi-k3s otbr-raspi-k3s2 otbr-raspi5"
got="$(q '[.[] | select(.kind == "Deployment") | .metadata.name] | sort | join(" ")')"
[ "$got" = "$want" ] || fail "Deployments are '$got', expected '$want'"
[ "$(q '[.[] | select(.kind == "Namespace")] | length')" = 0 ] || fail "the chart renders a Namespace"

# Selectors are immutable, and pod template labels equal to them keep pods from restarting.
declare -A mac=([raspi5]=90:64:9B:AB:3F:98 [raspi-k3s]=90:64:9B:AB:3E:78 [raspi-k3s2]=90:64:9B:AB:40:64)
for node in raspi5 raspi-k3s raspi-k3s2; do
    d="$(jq -c --arg n "otbr-$node" '.[] | select(.kind == "Deployment" and .metadata.name == $n)' "$tmp/default.json")"
    [ -n "$d" ] || { fail "no Deployment otbr-$node"; continue; }
    sel="$(jq -cS '.spec.selector.matchLabels' <<<"$d")"
    [ "$sel" = "$(jq -ncS --arg n "$node" '{"app.kubernetes.io/name": "otbr", "thread-br/node": $n}')" ] \
        || fail "otbr-$node selector is $sel"
    [ "$(jq -cS '.spec.template.metadata.labels' <<<"$d")" = "$sel" ] || fail "otbr-$node pod labels differ from its selector"
    dev="$(jq -r '.spec.template.spec.containers[0].env[] | select(.name == "DEVICE") | .value' <<<"$d")"
    [ "$dev" = "/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_${mac[$node]}-if00" ] \
        || fail "otbr-$node opens $dev"
    [ "$(jq -r '.spec.template.spec.nodeSelector["kubernetes.io/hostname"]' <<<"$d")" = "$node" ] \
        || fail "otbr-$node is not pinned to $node"
done
m="$(jq -c '.[] | select(.kind == "Deployment" and .metadata.name == "matter-server")' "$tmp/default.json")"
if [ -n "$m" ]; then
    sel="$(jq -cS '.spec.selector.matchLabels' <<<"$m")"
    [ "$sel" = '{"app.kubernetes.io/name":"matter-server"}' ] || fail "matter-server selector is $sel"
    [ "$(jq -cS '.spec.template.metadata.labels' <<<"$m")" = "$sel" ] || fail "matter-server pod labels differ from its selector"
    # It runs on a border-router node, where it reaches the Thread network through that
    # node's own wpan0; the node label, not a list of host names, says which nodes those are.
    [ "$(jq -cS '.spec.template.spec.nodeSelector' <<<"$m")" = '{"thread-br":"true"}' ] \
        || fail "matter-server nodeSelector is $(jq -cS '.spec.template.spec.nodeSelector' <<<"$m")"
    [ "$(jq -c '.spec.template.spec.affinity' <<<"$m")" = null ] || fail "matter-server still has an affinity"
fi

# The Matter fabric survives an uninstall.
[ "$(q '[.[] | select(.kind == "PersistentVolumeClaim" and .metadata.name == "matter-server")
          | .metadata.annotations["helm.sh/resource-policy"]] | join(",")')" = keep ] \
    || fail "PVC matter-server missing or without helm.sh/resource-policy: keep"

# Every image is pinned by tag and digest.
q '.[] | select(.kind == "Deployment") | "\(.metadata.name) \(.spec.template.spec.containers[].image)"' |
    while read -r name image; do
        [[ "$image" =~ ^[^@\ ]+:[^@\ ]+@sha256:[0-9a-f]{64}$ ]] || echo "$name $image"
    done > "$tmp/unpinned"
[ ! -s "$tmp/unpinned" ] || fail "images not pinned by tag and digest: $(paste -sd';' "$tmp/unpinned")"

# A per-router image changes that router only (the canary pattern).
canary="example.invalid/x:1@sha256:$(printf '0%.0s' {1..64})"
# Through a values file: --set on a list index makes Helm replace the whole list.
yq "(.borderRouters[] | select(.node == \"raspi-k3s2\") | .image) = \"$canary\"" thread/values.yaml > "$tmp/canary-values.yaml"
render -f "$tmp/canary-values.yaml" > "$tmp/canary.json"
images() { jq -r '[.[] | select(.kind == "Deployment") | "\(.metadata.name)=\(.spec.template.spec.containers[0].image)"] | sort | .[]' "$1"; }
changed="$(diff <(images "$tmp/default.json") <(images "$tmp/canary.json") | grep '^>' | cut -d' ' -f2 || true)"
[ "$changed" = "otbr-raspi-k3s2=$canary" ] || fail "a per-router image for raspi-k3s2 changed: ${changed:-nothing}"

if [ "$failures" -gt 0 ]; then
    echo "$failures invariant(s) failed" >&2
    exit 1
fi
echo "PASS: all invariants hold"
