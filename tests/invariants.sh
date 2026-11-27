#!/usr/bin/env bash
# Properties of the rendered chart that must hold whatever the values are. Each one guards
# something that would hurt if it broke: an immutable selector, how a border router finds its
# radio and upgrades, the Matter fabric's volume, digest pinning, and pod templates that stay
# the same across chart versions.
#
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


# One DaemonSet for the border routers, on every thread-br node; no per-node Deployments.
# The chart never owns the namespace.
[ "$(q '[.[] | select(.kind == "Deployment") | .metadata.name] | sort | join(" ")')" = matter-server ] \
    || fail "Deployments are $(q '[.[] | select(.kind == "Deployment") | .metadata.name] | join(" ")'), expected only matter-server"
[ "$(q '[.[] | select(.kind == "DaemonSet") | .metadata.name] | join(" ")')" = otbr ] || fail "no single DaemonSet otbr"
[ "$(q '[.[] | select(.kind == "Namespace")] | length')" = 0 ] || fail "the chart renders a Namespace"
d="$(jq -c '.[] | select(.kind == "DaemonSet" and .metadata.name == "otbr")' "$tmp/default.json")"
if [ -n "$d" ]; then
    dq() { jq -cS "$1" <<<"$d"; }
    # Selectors are immutable, and pod labels equal to them keep pods from restarting.
    [ "$(dq '.spec.selector.matchLabels')" = '{"app.kubernetes.io/name":"otbr"}' ] || fail "otbr selector is $(dq '.spec.selector.matchLabels')"
    [ "$(dq '.spec.template.metadata.labels')" = "$(dq '.spec.selector.matchLabels')" ] || fail "otbr pod labels differ from its selector"
    [ "$(dq '.spec.template.spec.nodeSelector')" = '{"thread-br":"true"}' ] || fail "otbr nodeSelector is $(dq '.spec.template.spec.nodeSelector')"
    # One node at a time, never a second pod on a node (radio and port 8081 exist once), and the
    # next node only after the replaced router has been back in the mesh for a minute.
    [ "$(dq '.spec.updateStrategy')" = '{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1},"type":"RollingUpdate"}' ] \
        || fail "otbr updateStrategy is $(dq '.spec.updateStrategy')"
    [ "$(dq '.spec.minReadySeconds')" = 60 ] || fail "otbr minReadySeconds is $(dq '.spec.minReadySeconds')"
    c="$(jq -c '.spec.template.spec.containers[0]' <<<"$d")"
    ready="$(jq -r '.readinessProbe.exec.command | join(" ")' <<<"$c")"
    [[ "$ready" == *"ot-ctl state"* && "$ready" == *child* && "$ready" == *router* && "$ready" == *leader* ]] \
        || fail "otbr readiness is not the mesh-state check: $ready"
    [ "$(jq -cS '.livenessProbe.tcpSocket' <<<"$c")" = '{"port":"rest"}' ] || fail "otbr liveness is not the REST port check"
    [ "$(jq -r '.env[] | select(.name == "DEVICE") | .value' <<<"$c")" = /dev/ttyOTBR ] || fail "otbr DEVICE is not /dev/ttyOTBR"
    [ "$(jq -c '.command' <<<"$c")" = '["/opt/thread/link-radio.sh"]' ] || fail "otbr command is $(jq -c '.command' <<<"$c")"
    # The wrapper learns its node from the downward API, to find an override for it.
    [ "$(jq -r '.env[] | select(.name == "NODE_NAME") | .valueFrom.fieldRef.fieldPath' <<<"$c")" = spec.nodeName ] \
        || fail "otbr NODE_NAME does not come from spec.nodeName"
    [ "$(jq -r '.env[] | select(.name == "RADIO_OVERRIDES") | .value' <<<"$c")" = /opt/thread/radio-overrides ] \
        || fail "otbr RADIO_OVERRIDES is not /opt/thread/radio-overrides"
fi

# A per-node radio override lands in the ConfigMap as "<node> <by-id name>", and changes the
# pod template (a checksum annotation), so the DaemonSet rolls it out node by node.
override="usb-Espressif_USB_JTAG_serial_debug_unit_90:64:9B:AB:3F:98-if00"
render --set "otbr.radioOverrides.raspi5=$override" > "$tmp/override.json"
[ "$(jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "otbr-scripts") | .data["radio-overrides"]' "$tmp/override.json")" = "raspi5 $override" ] \
    || fail "radio override not rendered into the ConfigMap"
pod_annotations() { jq -cS '.[] | select(.kind == "DaemonSet") | .spec.template.metadata.annotations' "$1"; }
[ "$(pod_annotations "$tmp/override.json")" != "$(pod_annotations "$tmp/default.json")" ] \
    || fail "a radio override does not change the DaemonSet's pod template, so it would never roll out"
# The wrapper and the probe the pods run are the tested files, byte for byte.
for f in link-radio.sh probe-radio.py; do
    diff <(q ".[] | select(.kind == \"ConfigMap\" and .metadata.name == \"otbr-scripts\") | .data[\"$f\"]") \
         "thread/files/$f" > /dev/null || fail "ConfigMap otbr-scripts does not carry thread/files/$f"
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
q '.[] | select(.kind == "Deployment" or .kind == "DaemonSet") | "\(.metadata.name) \(.spec.template.spec.containers[].image)"' |
    while read -r name image; do
        [[ "$image" =~ ^[^@\ ]+:[^@\ ]+@sha256:[0-9a-f]{64}$ ]] || echo "$name $image"
    done > "$tmp/unpinned"
[ ! -s "$tmp/unpinned" ] || fail "images not pinned by tag and digest: $(paste -sd';' "$tmp/unpinned")"

# A new chart version must not change any pod template: a difference there restarts every
# border router and the Matter server on each App upgrade, even when nothing else changed.
helm package thread -d "$tmp/v1" --version 0.0.1 > /dev/null
helm package thread -d "$tmp/v2" --version 0.0.2 > /dev/null
templates() {
    helm template thread "$1" --namespace thread | yq -o=json -I=0 'select(.kind == "Deployment" or .kind == "DaemonSet")' \
        | jq -cS '{("\(.kind)/\(.metadata.name)"): .spec.template}' | jq -sS 'add'
}
diff <(templates "$tmp/v1/thread-0.0.1.tgz") <(templates "$tmp/v2/thread-0.0.2.tgz") > "$tmp/template-drift" \
    || fail "pod templates change with the chart version: $(grep -c '^[<>]' "$tmp/template-drift") lines differ"

if [ "$failures" -gt 0 ]; then
    echo "$failures invariant(s) failed" >&2
    exit 1
fi
echo "PASS: all invariants hold"
