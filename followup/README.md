# Follow-up

What is running, what has not been proven yet, and what to look at when coming back to
this. Written 2026-11-16, the day everything was deployed. The blow-by-blow record is
[`../docs/deploy-log.md`](../docs/deploy-log.md).

## What runs

| Node | Radio (base MAC) | Deployment | REST API |
|---|---|---|---|
| `raspi5` | `90:64:9b:ab:3f:98` | `otbr-raspi5` | `http://192.168.0.240:8081` |
| `raspi-k3s` | `90:64:9b:ab:3e:78` | `otbr-raspi-k3s` | `http://192.168.0.242:8081` |
| `raspi-k3s2` | `90:64:9b:ab:40:64` | `otbr-raspi-k3s2` | `http://192.168.0.241:8081` |

All in namespace `thread`, together with `matter-server` (Service
`matter-server.thread.svc.cluster.local:5580`). One Thread network, `ha-thread-fad4`,
channel 15, preferred in Home Assistant, which has one OpenThread Border Router integration
per node plus Thread and Matter.

A quick health check without Grafana:

```sh
for ip in 240 242 241; do curl -s http://192.168.0.$ip:8081/node/state; echo; done
```

Expect one `"leader"` and two `"router"`. `"detached"` or `"disabled"` means that border
router is not in the mesh. The bare URL without a path answers 404; that is normal.

## Monitoring

Files in [`../k8s/monitoring/`](../k8s/monitoring/).

**Dashboard "Thread border routers"** (uid `thread-border-routers`): RCP trouble lines,
container restarts, pods ready, Thread role changes, and the kernel's USB events for the
radios. The source is `dashboard-thread.json`; `build-configmap.sh` embeds it into
`dashboard-configmap.yaml`, which is what gets applied.

**Three alert rules** in `alert-rules.yaml`: an RCP failure line, fewer than 4 pods ready,
a container restart. Grafana's alerting is provisioned from the Helm values of the
monitoring release, so the group lives in `upgrade_nodes/k3s/monitoring/values.yaml`
(group `thread`, folder `Thread`); the file here is its source. Change both together, then
run the Helm upgrade documented there and restart Grafana.

Applied 2026-11-16: dashboard ConfigMap `thread-border-routers-dashboard` in `monitoring`,
and Helm release `victoria-metrics` revision 48 with the alert group. After the restart
Grafana reported 3 rules in `Thread;thread` and 0 evaluation failures. Not done: nobody has
looked at the dashboard in a browser yet, and no rule has ever fired, so the path from a
firing rule to a mail is unproven for these three.

Where the data comes from, checked on 2026-11-16:

| Source | Reaches | Selector |
|---|---|---|
| OTBR and Matter server container logs | VictoriaLogs, through `vlagent` | `kubernetes.pod_namespace:thread` |
| Kernel USB events on the nodes | VictoriaLogs, through Vector | `host:raspi5 unit:kernel` |
| Restart and readiness counters | VictoriaMetrics, from kube-state-metrics | `{namespace="thread"}` |

The radios themselves log nothing: the firmware is built without log output, because the
USB port carries Spinel. Everything known about a radio is what OTBR says about it.

The lines that count as RCP trouble:

```
kubernetes.pod_namespace:thread kubernetes.container_name:otbr
  ("RCP failure detected" OR "Unexpected RCP reset" OR "radio tx timeout"
   OR "Init() at spinel_driver" OR "WARNING: otbr-agent exited")
```

The first three are OpenThread's own messages, taken from the upstream issue reports; none
has been seen here yet, so the exact wording is unconfirmed against this OTBR build. The
23 hits on `raspi5` on 2026-11-16 are the two start-up bugs of that day
(`Init() at spinel_driver`), not radio failures in operation.

How to read it:

- **Nothing for a week:** the USB patches hold. Note it in the deploy log.
- **A hit every few days on any node, OTBR recovers:** the known upstream problem, at a
  rate that does no harm.
- **Hits every hour or two:** the patches do not help. That was the unpatched rate
  reported upstream. See "Upstream" below.
- **Hits on one node only:** suspect that board, its extension cable or its USB port. Swap
  two boards and see whether the hits follow the board.

## Which router each device uses

The Matter server's own dashboard has it: the name set in `matterServer.ingress.host`, then Network, then
Thread. The name follows the pod; it is limited to `lan-only@file` and has no login (so
anyone it admits can add and remove devices). Without Traefik: `http://<node>:5580` on
whichever node runs `matter-server`. It draws devices,
border routers and links, coloured by signal strength; clicking a device lists its links with
RSSI and LQI (0 to 3, 3 is best). The data are the devices' own Thread diagnostics, so a sleepy
device's links can be minutes old, and an offline device keeps its last known links. The same
graph comes from the WebSocket command `get_network_topology`; use `refresh: false`, which reads
the cache and causes no radio traffic.

The BILRESA remotes report an implausible average RSSI for their parent (-11 dBm); their last
RSSI, and the parent's view of them, are realistic.

## Radio coverage

The floors are 20 cm reinforced concrete. Between floors the border routers reach each other
over Ethernet (TREL), and their radio links are marginal (about -95 dBm) or absent. Each
radio is there to serve its own floor. Check link types with
`ot-ctl multiradio neighbor list`; an RSSI of exactly -20 in `ot-ctl neighbor table` is
TREL's placeholder, not a radio measurement. Seeed documents "up to 80m" for BLE and Wi-Fi
with the onboard antenna and nothing for Thread. OTBR transmits at 6 dBm.

If a room on a floor turns out weak: first a mains-powered Thread device there, which
routes for the mesh; then an external U.FL antenna on that floor's board, which needs
`XIAO_USE_EXTERNAL_ANTENNA 1` in patch 0003 and a reflash.

## Status on 2026-11-26

Seven devices commissioned, five available; the two GRILLPLATS plugs are unplugged on
purpose and show as unavailable until they are plugged in again.
No RCP trouble lines and no restarts in ten days. A node reboot (`raspi-k3s`, 20 Nov)
was survived without intervention. Details in the deploy log. Items 1, 3 and 5 below are
therefore done; failover (2) and a replug while running (4) are still open.

## Not proven yet

Nothing below has been tested. Each is a short job once a Matter-over-Thread device is at
hand.

1. **Commission a device.** Home Assistant phone app, Settings → Devices & services → Add
   device → Matter, scan the code. On Android first sync the Thread credentials in the
   companion app. Then note the device's address and which router it attached to
   (`ot-ctl child table`, `ot-ctl neighbor table` on each border router).
2. **Failover.** Scale one border router to 0 and check the device stays reachable in Home
   Assistant. Do `raspi5` last and watch it closest, for the reason in the next section.
3. **Reboot of a border-router node.** The firmware fix for cold power-on was confirmed by
   replugging, once per board. A full reboot of the Pi has not been tried.
4. **Replug while OTBR is running.** Expected: OTBR exits, the container restarts and finds
   the radio again. The directory mount of `/dev/serial/by-id` was made for this case and
   has not been exercised.
5. **A week of uptime** without RCP trouble lines.

## Known weak spot: routes on NetworkManager 1.42

To reach a Thread device from the LAN, a host needs a route to the Thread prefix
(`fd59:2881:fdab:1::/64`) through a border router. Each border router advertises one.
What the nodes made of that on 2026-11-16:

| Node | Next hops kept |
|---|---|
| `mini-k3s` (systemd-networkd) | all three |
| `raspi-k3s2` (NetworkManager 1.52) | two |
| `raspi-k3s` (NetworkManager 1.42) | one |
| `raspi5` (NetworkManager 1.42) | none learned; it uses its own `wpan0` |

The Matter server runs on `raspi5`. If the border router on `raspi5` stops, `raspi5` has to
pick up a route through another one, and NetworkManager 1.42 is the version known not to
handle that well. Check during the failover test:

```sh
ssh raspi5.local ip -6 route show fd59:2881:fdab:1::/64
```

If no route appears within a few minutes, pin the Matter server to `raspi-k3s2` or
`mini-k3s` with `matterServer.nodeSelector` in [`../thread/values.yaml`](../thread/values.yaml)
(`mini-k3s` uses `eno1`, so `matterServer.primaryInterface` changes with it). Upgrading the two
Debian 12 nodes to Debian 13 would fix it at the root.

## Open questions

- **Home Assistant is on host networking since 2026-11-16**, so that it can discover the
  border routers. Its trusted proxies are in `/config/.storage/http`, not in
  `configuration.yaml`; see `upgrade_nodes/k3s/home-assistant/README.md`. It now sees the
  node's Bluetooth adapter: leave a "discovered: Bluetooth" card alone, `theengs-gateway`
  uses that adapter.
- **USB sticks.** The Kingston DataTraveler sticks on `raspi5` and `raspi-k3s2` (and the one
  already pulled from `raspi-k3s`) are the former Longhorn disks, label `longhorn`, retired
  on 2026-10-28. Checked 2026-11-16: not mounted, not in `/etc/fstab`, no open handles, not
  a Longhorn disk on the node. They can be removed.
- **1-Wire adapter on `raspi5`.** The radio went into the USB port of the DS1490F adapter
  (`04fa:2490`), which has been unplugged since. The node still carries `w1-sensor=true`.
  Whatever read those sensors has lost them.
- **Unauthenticated ports on the LAN.** OTBR's REST API (8081 on three nodes) hands out the
  Thread network key, and the Matter server (5580) accepts commands, from anyone on the LAN.
  Accepted for now.
- **Privileged containers.** The border routers run `privileged: true`, because that is the
  only way to open a host serial device without a device plugin.

## Upstream, to revisit

Checked 2026-11-26.

| What | State | Action |
|---|---|---|
| ESP-IDF driver fix for false USB disconnects (esp-idf#18490) | merged to master on 2026-11-10 as `3c68628dcb`, the same fix as patch 0001 plus a chip-revision guard; **not in any release**, not on `release/v6.1`; latest release still v6.1.1 | when a release contains `3c68628dcb`: drop patch 0001, bump ESP-IDF, rebuild, reflash, cold-start test |
| The OpenThread port defects (byte-wise TX that drops data, fatal `EIO` on read; esp-idf#19343, raised again in #18490 on 2026-11-24) | still in master; Espressif has not said whether it will change the port | keep patch 0002 until that lands |
| `ownbee/hass-otbr-docker` | **v0.5.0** released 2026-11-23, on app 3.4.0 (OTBR stable v2026.10.0); arm64 and amd64; no environment variables changed; digest `sha256:2f927f06f803c5dd16f97f8aad752c53d92e2c3b1de90fe4273f278fc6cc8206` | done, see below |
| `matter-js/matterjs-server` | **1.6.1** released 2026-11-25, running since 2026-11-26: matter.js 0.18.1, re-subscribes when a device stops mid-update, events before the first read are no longer lost, graph layout fix; the rest is BLE proxy; digest `sha256:5591f9f65926ca4b13b34cfd9c9888cb9d9ee9f147fe0b04c8e025cbeeee0eb7` | done |
| NetworkManager | `raspi5`, `raspi-k3s` still Debian 12, NM 1.42.4; `raspi-k3s2` Debian 13, NM 1.52.1 | Debian 13 upgrade of those two, independent of this project |

What OTBR v2026.10.0 changes for this setup: routes to external networks announced by *other*
border routers (Apple, Google) are no longer installed on the host, channel changes go through
the leader, and otbr-agent's log lines lose their uptime prefix. RCP API stays at 11, the same as
the radios, so no reflash is needed. The RCP alert matches message text, not the prefix, so it
keeps working.

Applied 2026-11-26: Matter server 1.6.1 everywhere, and OTBR container v0.5.0 on
`raspi-k3s2` only, as a canary. On 2026-11-27 the other two followed; all three run v0.5.0. No
device went offline. The backup `/var/lib/otbr.bak-20261126` on `raspi-k3s2` can go.

Renovate keeps the image digests in `thread/values.yaml` current and automerges minor, patch
and digest updates once the `lint` check passes; that publishes a chart version but does not
upgrade the running App. The ESP-IDF version in `firmware/build.sh` is bumped by hand.

## Routine jobs

**Rebuild and flash a radio.** `./firmware/build.sh`, then on the workstation
`uvx esptool --chip esp32c6 --port /dev/cu.usbmodemXXXX write-flash 0x0 firmware/out/ot_rcp-xiao-esp32c6.bin`
and `uv run --with pyserial firmware/tools/rcp_probe.py /dev/cu.usbmodemXXXX`. That probe
runs after a reset, which hides cold-start bugs: after plugging the board into its Pi, check
that OTBR actually starts.

**Change anything in the border routers or the Matter server.** Edit
[`../thread/values.yaml`](../thread/values.yaml), run `helm lint thread && tests/invariants.sh`,
merge to `main` (a pull request needs the `lint` check), wait for the release workflow, then
Upgrade the `thread` App in Rancher. Never `kubectl apply` these objects any more: Helm owns
them, and the next upgrade would undo a hand change.

**Upgrade an image.** Renovate opens the pull request and merges minor, patch and digest updates
by itself once `lint` passes; that only publishes a chart version. **An App upgrade that changes
`otbr.image` restarts all three border routers at the same moment** (each Deployment is
`Recreate`), so the mesh has no border router for those seconds. To try a new border-router
image on one node first: after Renovate's merge, set `image:` to the *old* image on two of the
three `borderRouters` entries, merge, upgrade the App (one router restarts), and after a day
remove those two lines and upgrade again.

**Replace a radio.** The new board has another MAC address: change that entry's `radioMac` in
`thread/values.yaml` to what `ls /dev/serial/by-id/` shows on the node, and the same MAC in the
`mac` table of `tests/invariants.sh`, which checks each router opens its own radio. The Thread credentials
are in `/var/lib/otbr` on the node and survive the swap.

**Add a border router.** Install `nodes/60-otbr.conf` as `/etc/sysctl.d/60-otbr.conf` on the
node, label it `thread-br=true`, add an entry to `borderRouters`, upgrade the App, then add the
URL in Home Assistant as another OpenThread Border Router. Raise the "4" in the pods-ready alert
and in the dashboard, and add the radio to `tests/invariants.sh`.

**Removing the App** deletes the border routers and the Matter server but keeps the PVC
`matter-server` with the Matter fabric (`helm.sh/resource-policy: keep`); reinstalling
picks it up again.

**See what a border router thinks.** On the node:
`sudo k3s crictl exec $(sudo k3s crictl ps --name otbr -q) ot-ctl state`, and likewise
`router table`, `child table`, `netdata show`, `dataset active` (the last one prints the
network key).
