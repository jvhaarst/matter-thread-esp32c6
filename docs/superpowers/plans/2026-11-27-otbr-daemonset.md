# Border routers as one DaemonSet with a mesh-aware rolling update: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three per-node OTBR Deployments in chart `thread` with one DaemonSet on every `thread-br=true` node, which upgrades node by node and moves on only when the restarted router is back in the mesh, so a border router is always up.

**Architecture:** A DaemonSet `otbr` selects nodes by `thread-br: "true"`, with `updateStrategy: RollingUpdate`, `maxUnavailable: 1`, `maxSurge: 0`, `minReadySeconds: 60`, and a readiness probe that passes only when `ot-ctl state` is `child`, `router` or `leader`. The radio is no longer named per node: a small wrapper script, mounted from a ConfigMap and run as the container command, finds the node's single radio by pattern, links it to `/dev/ttyOTBR`, and `exec`s the image's `/init`.

**Tech Stack:** Helm 4, chart `thread`, ownbee/hass-otbr-docker v0.5.0 (s6-overlay, entrypoint `/init`), `yq`, `jq`, Rancher App upgrade.

**Spec:** the session of 2026-11-27: the user wants an upgrade that always leaves an active border router, and no per-router naming, so that a new router needs no new named pod. Background: [`../../design.md`](../../design.md), [`../../../followup/README.md`](../../../followup/README.md).

## Global Constraints

- One radio per border-router node; its by-id name matches `usb-Espressif_USB_JTAG_serial_debug_unit_*-if00`. Zero or more than one match: the container exits non-zero with a message naming the count, and otbr-agent never starts.
- `DEVICE` is `/dev/ttyOTBR` for every pod. The wrapper links it inside the container's own `/dev` (a writable tmpfs); nothing is written on the node.
- The container command is the wrapper; it ends with `exec /init` so s6-overlay stays PID 1.
- Kept unchanged: `hostNetwork`, `privileged`, the `/dev/serial/by-id` directory mount, the state hostPath `/var/lib/otbr`, REST on 8081, all OTBR env values, the image reference, resources, liveness and startup probes.
- Node selection: `thread-br: "true"` only. Adding a border router is labelling a node (plus its sysctl file); the chart does not change.
- The Matter server, its Service, PVC and Ingress are not touched.
- The migration (Deployments to DaemonSet) restarts all three border routers once; it needs the user's OK and a quiet moment.
- Every cluster change and every merge to `main` needs the user's OK at the step marked **GATE**.

## Review Focus

1. **The wrapper does not run in this image the way the test assumes** (s6 refusing a non-PID-1 `/init`, `/dev` read-only in some runtime). Expected: proven in a throwaway pod before the migration (Task 2).
2. **A router that never becomes ready** (radio unplugged, wrong count) halts the rollout instead of taking down the next node. Expected: DaemonSet stops at that node; the others keep running. Pinned by `maxUnavailable: 1` and the readiness probe assertions in Task 1.
3. **Readiness flapping**: a router briefly `detached` during normal operation must not be killed. Expected: readiness failure only removes it from Ready, never restarts it; liveness stays the TCP check. Asserted in Task 1.
4. **The Deployments and the DaemonSet fighting over host port 8081 and the radio during the migration.** Expected: DaemonSet pods wait (Pending) until Helm has deleted the Deployments; then each node starts. Checked in Task 3.
5. **Pod template drift across chart versions**: the existing invariant must cover the DaemonSet's template. Asserted in Task 1.

---

### Task 1: Chart change, test-first

**Files:**
- Create: `thread/files/link-radio.sh`, `thread/templates/otbr-configmap.yaml`, `thread/templates/otbr-daemonset.yaml`, `tests/link-radio.sh`
- Delete: `thread/templates/otbr-deployments.yaml`
- Modify: `thread/values.yaml` (remove `borderRouters`; add `otbr.radioPattern`, `otbr.nodeSelector`), `thread/templates/NOTES.txt`, `tests/invariants.sh`

**Interfaces:**
- `thread/files/link-radio.sh`: environment `RADIO_DIR` (default `/dev/serial/by-id`), `RADIO_PATTERN` (default `usb-Espressif_USB_JTAG_serial_debug_unit_*-if00`), `RADIO_LINK` (default `/dev/ttyOTBR`); arguments: the command to exec, default `/init`. Exactly one match: `ln -sf` it to `RADIO_LINK`, print `radio <name> linked to <link>`, exec the command. Otherwise print `expected exactly one radio matching <pattern> in <dir>, found <n>` to stderr and exit 1.
- ConfigMap `otbr-scripts` with key `link-radio.sh`, mounted at `/opt/thread`, `defaultMode: 0555`.
- Values: `otbr.radioPattern`, `otbr.nodeSelector` (`{thread-br: "true"}`); everything else under `otbr` as today.

- [ ] **Step 1: `tests/link-radio.sh`** runs the script against temp directories: one matching file and command `true` (exit 0, link points at it, message printed); none (exit 1, message `found 0`); two (exit 1, `found 2`); one matching plus one non-matching file (exit 0).
- [ ] **Step 2: Rewrite the OTBR part of `tests/invariants.sh`:** exactly one DaemonSet `otbr` and no OTBR Deployment; selector `{app.kubernetes.io/name: otbr}` equal to the pod labels; `nodeSelector` `{thread-br: "true"}`; `updateStrategy` RollingUpdate with `maxUnavailable: 1` and `maxSurge: 0`; `minReadySeconds: 60`; readiness probe is an exec of `ot-ctl state` accepting `child|router|leader`, liveness still `tcpSocket` on `rest`; `DEVICE` is `/dev/ttyOTBR`; command is `/opt/thread/link-radio.sh`; the ConfigMap's script equals `thread/files/link-radio.sh`. Drop the per-router MAC and override cases. Keep the Matter server, PVC, digest and drift checks; the drift check must include DaemonSets.
- [ ] **Step 3: Run both tests.** Expected: both FAIL (no script, no DaemonSet).
- [ ] **Step 4: Write the script, ConfigMap, DaemonSet, values and NOTES.** The ConfigMap content comes from `.Files.Get "files/link-radio.sh"`. Carry the existing comments over (privileged reason, by-id directory mount, hostNetwork). `strategy: Recreate` goes; explain in a comment why the DaemonSet's `maxSurge: 0` is required (radio and port 8081 exist once per node).
- [ ] **Step 5: `helm lint thread`, `tests/link-radio.sh`, `tests/invariants.sh`.** Expected: all pass. Show the drift check fails with a chart-version annotation in the DaemonSet's pod template, then restore.
- [ ] **Step 6: Commit** on branch `otbr-daemonset`: `Border routers as one DaemonSet that upgrades node by node`.

### Task 2: Prove the wrapper in the real image

- [ ] **Step 1: GATE.** Show the throwaway Pod: namespace `thread`, image = `otbr.image`, command the wrapper, ConfigMap rendered from the branch, an `emptyDir` at `/dev/serial/by-id` holding one empty file named like a radio, not privileged, not `hostNetwork`, `restartPolicy: Never`, on any node.
- [ ] **Step 2: Run it.** Expected in its log: `radio usb-Espressif_USB_JTAG_serial_debug_unit_TEST-if00 linked to /dev/ttyOTBR`, followed by s6-overlay start lines (`s6-rc: info: service` …) and the image banner. otbr-agent then failing on the fake device is expected. Second run with an empty `emptyDir`: log shows `found 0`, pod `Failed`, no s6 lines.
- [ ] **Step 3: Delete both pods and the temporary ConfigMap.** Record the log lines in `docs/deploy-log.md`.

### Task 3: Migrate

- [ ] **Step 1: PR and merge.** Push `otbr-daemonset`, open a PR, `lint` must pass. **GATE**: merge. Expected: release publishes the next chart version.
- [ ] **Step 2: Baseline.** Partition, role and `rcp version` per node; Matter nodes 1 to 5 available.
- [ ] **Step 3: GATE, then the user upgrades** the `thread` App in Rancher to the new version. Expected: Deployments `otbr-*` deleted; DaemonSet `otbr` with three pods, one per `thread-br` node, each Ready; each node's otbr log shows `radio … linked to /dev/ttyOTBR` with that node's own MAC; all three back on partition `370331428`; Matter nodes 1 to 5 available within 3 minutes; Home Assistant's three OTBR integrations answer (same node addresses, port 8081).
- [ ] **Step 4: If the upgrade fails:** Rancher rollback to the previous revision restores the three Deployments; verify as in Step 2.

### Task 4: Prove the rolling update

- [ ] **Step 1: GATE, then** `kubectl -n thread rollout restart daemonset/otbr`, and record the pods' replacement times and Ready transitions.
- [ ] **Step 2: Expected:** the pods are replaced one node at a time; each next node starts only after the previous pod has been Ready for 60 s; at every moment at least two routers report `router` or `leader`; no Matter device goes unavailable. Record the timeline in `docs/deploy-log.md`.

### Task 5: Documents

**Files:** Modify `followup/README.md` (Routine jobs: add a border router = sysctl file + label `thread-br=true` + add it in Home Assistant, no chart change; replace a radio = plug it in, nothing to change; upgrade an image = Renovate merge, then Upgrade in Rancher rolls node by node; remove the per-router canary text), `docs/design.md` (superseded note: DaemonSet replaces per-node Deployments, and why the earlier objection no longer holds), `README.md` if it names Deployments, Grafana alert description in `k8s/monitoring/alert-rules.yaml` and `upgrade_nodes/k3s/monitoring/values.yaml` (pod names `otbr-raspi5` etc. become `otbr-xxxxx`; only the description text changes, the expression is unchanged).

- [ ] **Step 1: Edit; `helm lint thread && tests/invariants.sh` still pass.**
- [ ] **Step 2: GATE, then commit, PR, merge** (`upgrade_nodes` change committed there separately, no Helm upgrade needed for a description-only change unless the user wants it live).
