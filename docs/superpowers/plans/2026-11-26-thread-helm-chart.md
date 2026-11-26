# Thread workloads as a Rancher-installed Helm chart: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-applied kustomize manifests in namespace `thread` with one Helm chart, published like the user's other chart repos and installed as a Rancher App, taking over the running objects without restarting them.

**Architecture:** A chart `thread` at the repository root renders the three OTBR Deployments, the Matter server Deployment, its Service, PVC and Ingress, with exactly the names, selectors and pod templates that run today. Two shell tests guard it: an equivalence test against the kustomize output (used during the migration) and an invariants test (kept in CI). GitHub Actions publish the chart to GitHub Pages; a Rancher ClusterRepo points at it; the live objects get Helm ownership metadata and the user installs the App from the Rancher UI, which adopts them.

**Tech Stack:** Helm 4 (local `v4.3.2`), kustomize via `kubectl kustomize`, `yq` v4, `jq`, GitHub Actions (`azure/setup-helm`, Pages), Renovate, Rancher 2.15.1 (`catalog.cattle.io/v1` ClusterRepo).

**Spec:** the decisions in this session on 2026-11-26 (summarised under Global Constraints), on top of [`../../design.md`](../../design.md) and the current manifests in `k8s/otbr/` and `k8s/matter-server/`.

## Global Constraints

- Pattern to copy: `~/code/time_dashboard_k8s` (chart directory at repo root, `.github/workflows/lint.yaml`, `.github/workflows/helm-release.yaml`, `renovate.json`). Publish URL `https://jvhaarst.github.io/matter-thread-esp32c6`.
- Chart name `thread`, directory `thread/`, Helm release name `thread`, namespace `thread`. The chart does not create the namespace.
- Object names stay: `otbr-raspi5`, `otbr-raspi-k3s`, `otbr-raspi-k3s2`, `matter-server` (Deployment, Service, PVC, Ingress), TLS secret `matter-server-tls`.
- Selectors stay: OTBR `{app.kubernetes.io/name: otbr, thread-br/node: <node>}`; Matter server `{app.kubernetes.io/name: matter-server}`. Pod template labels are exactly the selector labels; Helm's own labels go on object metadata only.
- Radios: `raspi5` `90:64:9B:AB:3F:98`, `raspi-k3s` `90:64:9B:AB:3E:78`, `raspi-k3s2` `90:64:9B:AB:40:64`.
- Images pinned by tag and digest. Start values: OTBR `ghcr.io/ownbee/hass-otbr-docker:v0.5.0@sha256:2f927f06f803c5dd16f97f8aad752c53d92e2c3b1de90fe4273f278fc6cc8206`, Matter server `ghcr.io/matter-js/matterjs-server:1.6.1@sha256:5591f9f65926ca4b13b34cfd9c9888cb9d9ee9f147fe0b04c8e025cbeeee0eb7`.
- The PVC `matter-server` holds the Matter fabric: it must carry `helm.sh/resource-policy: keep` and must never be recreated.
- Out of scope, stay as they are: namespace manifest (PSA labels), node sysctl file, firmware, Grafana dashboard ConfigMap and alert rules (namespace `monitoring`).
- Renovate: copy the user's global rule (minor/patch/digest/pin automerge, `automergeType: pr`, `platformAutomerge: true`), repository `allow_auto_merge` and `delete_branch_on_merge`, ruleset `main protection` on `~DEFAULT_BRANCH` with `deletion`, `non_fast_forward`, required check pinned to `integration_id: 15368`, `strict_required_status_checks_policy: false`, bypass `actor_id: 5` `RepositoryRole` `always`. Confirm the check name from a real check run.
- Merging to `main` only publishes a chart version. Upgrading the running App stays a manual action in Rancher.
- Every cluster change, the GitHub repository creation and the push need the user's explicit OK at the step marked **GATE**.

## Review Focus

1. **Pod template drift.** Any extra label, annotation or field in a rendered pod template makes the install roll all three border routers and the Matter server at once. Expected: install changes object metadata only. Pinned by `tests/equivalence.sh` (Task 2) and the live server-side diff (Task 6).
2. **Fabric loss.** Uninstalling the App, or a rename of the PVC in the chart, must not delete the Matter fabric. Expected: PVC kept. Pinned by the `keep`-policy and name assertions in `tests/invariants.sh` (Task 2).
3. **Per-router image override (the canary pattern).** Setting an image for one border router must change that Deployment only. Pinned by the override case in `tests/invariants.sh` (Task 2).
4. **Ownership or field-manager conflict at install.** The live objects were applied server-side by manager `kubernetes-mcp-server`; Helm 4 installs with server-side apply. Expected: no conflict, because every rendered value equals the live one; any conflict aborts the install with nothing changed. Checked in Task 6 by pod ages and `helm list` before and after.
5. **Selector immutability.** A selector that differs from the live one fails the install with `field is immutable`. Pinned by the selector assertions in `tests/invariants.sh` and by the equivalence test.

---

### Task 1: Finish the v0.5.0 canary (precondition)

Not chart work, but the chart starts with all three routers on v0.5.0.

**Files:**
- Modify: `k8s/otbr/base/deployment.yaml` (image line)
- Modify: `k8s/otbr/overlays/raspi-k3s2/kustomization.yaml` (remove the canary patch)
- Modify: `docs/deploy-log.md`, `followup/README.md`

- [ ] **Step 1: Check the canary held.** Not before 2026-11-27 19:51 UTC. On `raspi5`, query VictoriaLogs:
  `_time:[2026-11-26T19:50:00Z, now] kubernetes.pod_namespace:thread kubernetes.pod_node_name:raspi-k3s2 ("RCP failure detected" OR "Unexpected RCP reset" OR "radio tx timeout" OR "Init() at spinel_driver" OR "WARNING: otbr-agent exited") | stats count() hits`
  Expected: `hits` 0, and `kubectl -n thread get pod -l thread-br/node=raspi-k3s2` shows 0 restarts. Otherwise stop and report.
- [ ] **Step 2: Move the v0.5.0 image into the base, delete the override.** `kubectl kustomize k8s/otbr | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].image'` prints the v0.5.0 reference three times.
- [ ] **Step 3: GATE, then apply** with `kubectl --context raspi5 apply --server-side --field-manager=kubernetes-mcp-server -k k8s/otbr`. Expected: `otbr-raspi5` and `otbr-raspi-k3s` roll; each returns to `leader`/`router` on partition `370331428`; Matter server reports nodes 1 to 5 `available=True` within 3 minutes.
- [ ] **Step 4: Remove `/var/lib/otbr.bak-20261126` on `raspi-k3s2`**, log, commit `Move all border routers to OTBR container v0.5.0`.

### Task 2: The chart, test-first

**Files:**
- Create: `tests/equivalence.sh`, `tests/invariants.sh`
- Create: `thread/Chart.yaml`, `thread/values.yaml`, `thread/.helmignore`, `thread/templates/_helpers.tpl`, `thread/templates/otbr-deployments.yaml`, `thread/templates/matter-server-deployment.yaml`, `thread/templates/matter-server-service.yaml`, `thread/templates/matter-server-pvc.yaml`, `thread/templates/matter-server-ingress.yaml`, `thread/templates/NOTES.txt`

**Interfaces:**
- Produces, `thread/values.yaml` keys used by Tasks 3 and 6:
  - `otbr.image` (string, full reference with digest), `otbr.backboneInterface` (`eth0`), `otbr.restPort` (`8081`), `otbr.logLevel` (`notice`), `otbr.stateHostPath` (`/var/lib/otbr`), `otbr.resources`
  - `borderRouters` (list of `{node, radioMac, image?}`; `image` optional, overrides `otbr.image` for that router)
  - `matterServer.image`, `matterServer.primaryInterface` (`eth0`), `matterServer.productionMode` (`true`), `matterServer.nodes` (`[raspi5, raspi-k3s2]`), `matterServer.storage.size` (`1Gi`), `matterServer.storage.storageClass` (`longhorn`), `matterServer.resources`
  - `matterServer.ingress.enabled` (`true`), `.host` (`matter.vanhaarst.net`), `.middlewares` (`lan-only@file`), `.clusterIssuer` (`letsencrypt-production`), `.tlsSecret` (`matter-server-tls`)
- Produces: `tests/invariants.sh` and `tests/equivalence.sh`, each exit 0 on pass, non-zero with a message on failure, run from the repo root with no arguments.

- [ ] **Step 1: Write `tests/equivalence.sh`.** Renders `helm template thread thread --namespace thread` and `kubectl kustomize k8s/otbr` plus `kubectl kustomize k8s/matter-server`, drops the `Namespace` object, and for every object compares `kind`, `metadata.name`, `metadata.namespace`, `.spec` in full (including `.spec.template`), with `yq -o=json | jq -S`. Fails on any difference or on an object present on one side only. Object `metadata` labels and annotations are excluded from the comparison, except the Ingress and PVC annotations, which are compared.
- [ ] **Step 2: Write `tests/invariants.sh`.** Assertions on `helm template thread thread --namespace thread`:
  - exactly the Deployments `otbr-raspi5`, `otbr-raspi-k3s`, `otbr-raspi-k3s2`, `matter-server`; no `Namespace` object
  - each OTBR selector equals `{app.kubernetes.io/name: otbr, thread-br/node: <node>}` and equals its pod template labels; Matter server selector equals `{app.kubernetes.io/name: matter-server}` and its pod template labels
  - each OTBR `DEVICE` env equals `/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_<radioMac>-if00` and its `nodeSelector` names its node
  - PVC named `matter-server` with annotation `helm.sh/resource-policy: keep`
  - every container image matches `^[^@ ]+:[^@ ]+@sha256:[0-9a-f]{64}$`
  - override case: rendering with `--set 'borderRouters[2].image=example.invalid/x:1@sha256:<64 zeros>'` changes the image of `otbr-raspi-k3s2` only
- [ ] **Step 3: Run both tests.** Expected: both FAIL (`Error: path "thread" not found` or equivalent).
- [ ] **Step 4: Write the chart.** Chart `version: 0.1.0`, no `appVersion`. Object metadata labels: the selector labels plus `helm.sh/chart`, `app.kubernetes.io/instance`, `app.kubernetes.io/managed-by`. Carry the explanatory comments of the kustomize manifests over to the templates or `values.yaml` (privileged reason, `/dev/serial/by-id` directory mount, `Recreate`, hostNetwork, `PRODUCTION_MODE`, `lan-only` contents).
- [ ] **Step 5: Run `helm lint thread`, then both tests.** Expected: lint `0 chart(s) failed`; both tests PASS.
- [ ] **Step 6: Commit** `Add Helm chart for the Thread border routers and Matter server`.

### Task 3: CI and Renovate

**Files:**
- Create: `.github/workflows/lint.yaml`, `.github/workflows/helm-release.yaml`, `renovate.json`

**Interfaces:**
- Consumes: `tests/invariants.sh` (Task 2), chart directory `thread/`.
- Produces: a workflow job whose check run is named `lint` (confirmed in Task 4).

- [ ] **Step 1: `lint.yaml`** as in `time_dashboard_k8s`, `paths: ['thread/**', 'tests/**']`, job id `lint`, steps `helm lint thread`, `helm template thread thread --namespace thread`, `tests/invariants.sh` (install `yq` v4 on the runner first). Not `tests/equivalence.sh`: it needs the kustomize files, which Task 7 deletes.
- [ ] **Step 2: `helm-release.yaml`** as in `time_dashboard_k8s` with `time-dashboard` replaced by `thread`, `paths: ['thread/**']`.
- [ ] **Step 3: `renovate.json`** with the global automerge rule and a regex custom manager over `thread/values.yaml`: `matchStrings` `image:\s*(?<depName>[^:\s]+):(?<currentValue>[^@\s]+)@(?<currentDigest>sha256:[a-f0-9]{64})`, `datasourceTemplate: docker`.
- [ ] **Step 4: Validate.** `actionlint .github/workflows/*.yaml` prints nothing; `npx --yes --package renovate renovate-config-validator renovate.json` ends with `Config validated successfully`.
- [ ] **Step 5: Commit** `Add chart lint and release workflows and Renovate config`.

### Task 4: Publish the repository

- [ ] **Step 1: GATE.** The user confirms: create `jvhaarst/matter-thread-esp32c6` as a **public** repository and push `main`. Before asking, show `git ls-files` and grep the tree for `networkkey|pskc|dataset active|BEGIN .*PRIVATE` (expect no hits); `firmware/out/` is ignored.
- [ ] **Step 2: Create and push.** `gh repo create jvhaarst/matter-thread-esp32c6 --public --source . --push`. Then `gh api -X PATCH repos/jvhaarst/matter-thread-esp32c6 -F allow_auto_merge=true -F delete_branch_on_merge=true` and Pages with `build_type: workflow`.
- [ ] **Step 3: Get a real check run.** `gh workflow run lint.yaml`, wait for completion, then `gh api repos/jvhaarst/matter-thread-esp32c6/commits/<sha>/check-runs | jq -r '.check_runs[].name'`. Expected: `lint`, conclusion `success`.
- [ ] **Step 4: Ruleset** `main protection` with the exact settings under Global Constraints, check context from Step 3. Verify with `gh api repos/jvhaarst/matter-thread-esp32c6/rulesets/<id>`.
- [ ] **Step 5: Release.** `gh workflow run helm-release.yaml`; then `curl -s https://jvhaarst.github.io/matter-thread-esp32c6/index.yaml | yq '.entries.thread[0].version'` prints `0.1.<run_number>`.

### Task 5: Rancher chart repository

- [ ] **Step 1: GATE, then apply** a `catalog.cattle.io/v1` `ClusterRepo` named `thread` with `spec.url: https://jvhaarst.github.io/matter-thread-esp32c6`. Keep its manifest in `k8s/rancher-clusterrepo.yaml`.
- [ ] **Step 2: Verify.** `kubectl get clusterrepo thread -o json | jq '.status.conditions'` shows `Downloaded` `True`. The user sees chart `thread` under Apps → Charts.
- [ ] **Step 3: Commit** `Rancher chart repository for the thread chart`.

### Task 6: Adopt the running objects and install the App

- [ ] **Step 1: Record the baseline.** Pod names and start times in `thread`; `ot-ctl state` and partition on each node; Matter nodes 1 to 5 available.
- [ ] **Step 2: Live server-side diff.** `helm template thread thread --namespace thread | kubectl --context raspi5 diff --server-side --field-manager=kubernetes-mcp-server -f -`. Expected: only object metadata labels and annotations change (`helm.sh/chart`, `app.kubernetes.io/instance`, `app.kubernetes.io/managed-by`, PVC `helm.sh/resource-policy`); no line under any `spec.template` and no `spec.selector`. Anything else: stop.
- [ ] **Step 3: GATE.** Show the diff and the commands of Step 4.
- [ ] **Step 4: Add ownership metadata** to the seven objects (four Deployments, Service, PVC, Ingress): label `app.kubernetes.io/managed-by=Helm`, annotations `meta.helm.sh/release-name=thread` and `meta.helm.sh/release-namespace=thread`. Pod start times unchanged afterwards.
- [ ] **Step 5: The user installs** in Rancher: Apps → Charts → `thread` → Install, namespace `thread`, name `thread`, default values.
- [ ] **Step 6: Verify.** `helm list -n thread` shows `thread` `deployed` revision 1; `helm get metadata thread -n thread` shows `catalog.cattle.io/ui-source-repo: thread`; pod names and start times equal the baseline; three border routers back in partition `370331428`; Matter nodes 1 to 5 available; `https://matter.vanhaarst.net` 200 from the LAN, 403 from `vpn.vanhaarst.net`. If the install failed: confirm with `helm list` and pod ages that nothing changed, report the error.

### Task 7: Remove the kustomize path, update the documents

**Files:**
- Delete: `k8s/otbr/base/`, `k8s/otbr/overlays/`, `k8s/otbr/kustomization.yaml`, `k8s/matter-server/`, `tests/equivalence.sh`
- Move: `k8s/otbr/namespace.yaml` → `k8s/namespace.yaml`
- Modify: `README.md`, `followup/README.md` ("Routine jobs": add or replace a border router and upgrade an image are now edits of `thread/values.yaml`, merge, then Upgrade in Rancher; the canary is a per-router `image`), `docs/design.md` (superseded note on the workload section), `docs/deploy-log.md`

- [ ] **Step 1: Delete, move, edit.** `tests/invariants.sh` and `helm lint thread` still pass.
- [ ] **Step 2: GATE, then commit and push** `Thread workloads are a Rancher App now; drop the kustomize manifests`. No release is published, because `thread/**` did not change. The lint workflow runs only on pull requests, so run `gh workflow run lint.yaml` and confirm its check run on the new `main` commit ends `success`.
