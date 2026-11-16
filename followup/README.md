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
a container restart. They are a group to append to the Grafana provisioning in
`upgrade_nodes/k3s/monitoring/values.yaml`, not something applied from this repository.

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
`mini-k3s` by changing the node affinity in
[`../k8s/matter-server/deployment.yaml`](../k8s/matter-server/deployment.yaml)
(`mini-k3s` uses `eno1`, so `PRIMARY_INTERFACE` changes with it). Upgrading the two
Debian 12 nodes to Debian 13 would fix it at the root.

## Open questions

- **1-Wire adapter on `raspi5`.** The radio went into the USB port of the DS1490F adapter
  (`04fa:2490`), which has been unplugged since. The node still carries `w1-sensor=true`.
  Whatever read those sensors has lost them.
- **USB stick on `raspi-k3s`.** A Kingston DataTraveler was unplugged when the radio went
  in. It was not mounted and nothing failed, but its purpose is unknown.
- **Unauthenticated ports on the LAN.** OTBR's REST API (8081 on three nodes) hands out the
  Thread network key, and the Matter server (5580) accepts commands, from anyone on the LAN.
  Accepted for now.
- **Privileged containers.** The border routers run `privileged: true`, because that is the
  only way to open a host serial device without a device plugin.

## Upstream, to revisit

| What | Now | When it changes |
|---|---|---|
| ESP-IDF fix for RCP over USB Serial/JTAG (esp-idf#18490, #19343) | announced 2026-11-09, not released | drop patches 0001 and 0002 in `firmware/patches/`, rebuild, reflash all three, cold-start test each |
| `ownbee/hass-otbr-docker` | v0.4.0, built on add-on image 3.3.0 | the add-on is at 3.4.0; bump the digest in `k8s/otbr/base/deployment.yaml` when ownbee follows, one node first |
| `matter-js/matterjs-server` | 1.6.0 | bump the digest in `k8s/matter-server/deployment.yaml` |
| NetworkManager on `raspi5`, `raspi-k3s` | 1.42 | Debian 13 brings 1.52 |

No Renovate configuration exists for this repository; the image digests and the ESP-IDF
version are bumped by hand.

## Routine jobs

**Rebuild and flash a radio.** `./firmware/build.sh`, then on the workstation
`uvx esptool --chip esp32c6 --port /dev/cu.usbmodemXXXX write-flash 0x0 firmware/out/ot_rcp-xiao-esp32c6.bin`
and `uv run --with pyserial firmware/tools/rcp_probe.py /dev/cu.usbmodemXXXX`. That probe
runs after a reset, which hides cold-start bugs: after plugging the board into its Pi, check
that OTBR actually starts.

**Replace a radio.** The new board has another MAC address, so the path in that node's
overlay under `k8s/otbr/overlays/` changes. Read it with `ls /dev/serial/by-id/` on the node.
The Thread credentials are in `/var/lib/otbr` on the node and survive the swap.

**Add a border router.** Copy an overlay, set node name and radio path, add it to
`k8s/otbr/kustomization.yaml`, install `nodes/60-otbr.conf` as `/etc/sysctl.d/60-otbr.conf`
on the node, label it `thread-br=true`, apply, then add the URL in Home Assistant as another
OpenThread Border Router. Raise the "4" in the pods-ready alert and in the dashboard.

**See what a border router thinks.** On the node:
`sudo k3s crictl exec $(sudo k3s crictl ps --name otbr -q) ot-ctl state`, and likewise
`router table`, `child table`, `netdata show`, `dataset active` (the last one prints the
network key).
