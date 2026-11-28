# Deploy log

## 2026-11-16: first border router on `raspi5`

Applied, in this order:

1. `nodes/60-otbr.conf` installed as `/etc/sysctl.d/60-otbr.conf` and loaded with
   `sysctl -p`. `net.ipv6.conf.all.forwarding` is now 1. The IPv6 default route and the
   routes learned from router advertisements were unchanged afterwards, as expected with
   NetworkManager handling them.
2. Node label `thread-br=true` on `raspi5`.
3. Namespace `thread` and Deployment `otbr-raspi5` from `k8s/otbr/`.

Result: `otbr-agent` runs, Thread state `disabled` (no network formed yet), REST API on
8081, mDNS hostname `raspi5-otbr`, TREL enabled, TX power 6 dBm. `avahi-daemon` and OTBR
both hold UDP 5353 without either failing to start. `ip6tables` has the
`OTBR_FORWARD_INGRESS` and `OTBR_FORWARD_EGRESS` chains ahead of the Kubernetes ones.

```
rcp version: openthread-esp32/051e4c4eb20-43cc05a9b; esp32c6
version:     OPENTHREAD/2a8b4a5; POSIX; Oct  6 2026
extaddr:     52719cc1c36918aa
```

### Open: the radio was unresponsive after being plugged in

On the first start the pod crash-looped: `Init() at spinel_driver.cpp:87: Failure`. The
radio answered nothing over Spinel, 14 minutes after it had been plugged into the Pi, with
either state of DTR and RTS. A hard reset through RTS brought it back, and OTBR then started
on the first attempt.

Not reproduced so far by: reopening the port repeatedly, resetting it with nobody reading
the boot output for 15 s, or leaving the port closed for 15 s after boot. Still untested: a
cold power-on (replug, or a reboot of the Pi) and a long idle period with the port closed.
The program counter saved at the reset was `0x408050d8`; the build does not keep the ELF
file yet, so it could not be resolved to a function.

Also seen in the boot output: the second-stage bootloader logs at INFO level onto the
Spinel link. The example's `CONFIG_BOOTLOADER_LOG_LEVEL_ERROR` is a deprecated name and no
longer takes effect in ESP-IDF v6.1.

### Side effect: 1-Wire adapter unplugged

The radio went into the USB port that held the DS1490F 1-Wire adapter
(`04fa:2490`), which is no longer attached to `raspi5`. The node still carries the label
`w1-sensor=true`.

## 2026-11-16, later: both problems of the first start explained

**Radio dead after a cold power-on: my own patch.** Reproduced by replugging: the radio
answered nothing, and the saved program counter `0x408050d8` resolved to the idle loop
(`esp_cpu_wait_for_intr`), so nothing had crashed; it simply never transmitted. The USB
driver only sends from its "FIFO empty" interrupt. On a cold boot the ROM and bootloader
output fills the FIFO before the host has enumerated the port, and the bus reset then
empties it without raising that interrupt. Stock ESP-IDF calls
`usb_serial_jtag_ll_txfifo_flush()` after every write, which sends a packet and so brings
the interrupt back. The first version of patch 0002 had removed that call. It is restored.
A reset through RTS did not show the problem, because the port stays enumerated across it.

The bootloader is now built with `CONFIG_BOOTLOADER_LOG_LEVEL_NONE`. The example's
defaults ask for `CONFIG_BOOTLOADER_LOG_LEVEL_ERROR`, yet the bootloader logged at INFO;
why was not investigated.

Not yet confirmed on hardware: the fixed firmware has to be flashed and cold-started.

**Crash loop after a replug: the hostPath.** The Deployment mounted the radio's own
`/dev/serial/by-id/...` path. While the radio was unplugged the container restarted, and
the container runtime created a *directory* at that path. udev could then not create the
symlink when the radio came back, and OTBR was handed a directory as its serial port
(`Init() at spinel_driver.cpp:75: Failure`). The Deployment now mounts the directory
`/dev/serial/by-id` read-only and passes the full path in `DEVICE`. The stray directory
was removed by hand with `rmdir` and the symlink restored with `udevadm trigger`.

## 2026-11-16, evening: fixes confirmed on `raspi5`

Board 1 reflashed with the fixed build (`sha256 6c9447c2…`, firmware timestamp
`2026-11-16 19:35:02 UTC`) and plugged back in. Probed 60 s after the cold plug-in, before
anything else had opened the port: it answered four times out of four. One trial.

Deployment re-applied with the `/dev/serial/by-id` directory mount. OTBR started on the
first attempt, REST up within 5 s, state `disabled`. The settings file
`/var/lib/otbr/thread/0_90649bfffeab3f98.data` from the earlier run was still there.

## 2026-11-16: Matter server

Applied `k8s/matter-server/`. `matter-server/1.6.0` runs on `raspi5`, answers on port 5580
directly and through the Service (`10.43.213.179`). It found the border router by mDNS and
registered its REST API on its own:

```
ThreadDiagnosticsService REST auto-registered xp=DEAD00BEEF00CAFE baseUrl=http://192.168.0.240:8081
```

That also shows OTBR's mDNS advertisement is visible on the LAN with `avahi-daemon` running
on the same node. BLE is disabled in the server. One DCL vendor-list fetch timed out at
start; the bundled snapshot was used.

## 2026-11-16: Thread network formed, Home Assistant connected

Done in the Home Assistant UI: the OpenThread Border Router integration
(`http://192.168.0.240:8081`), the Thread integration, and the Matter integration
(`ws://matter-server.thread.svc.cluster.local:5580/ws`, no add-on).

| | |
|---|---|
| Network name | `ha-thread-fad4` |
| Channel | 15 |
| PAN ID | `0xfad4` |
| Extended PAN ID | `c513a0887b2d31ee` |
| Mesh-local prefix | `fd9f:fcf7:8bbe:458d::/64` |
| Off-mesh routable prefix | `fd59:2881:fdab:1::/64` |
| Preferred in Home Assistant | yes |

`raspi5` is leader (RLOC16 `0x4000`, extended address `faca7128f20509b2`). The network key
is in Home Assistant's `thread.datasets` store and in `/var/lib/otbr` on the node, and
deliberately not in this repository.

Route to the off-mesh prefix, learned from `raspi5`'s router advertisement:

| Node | Route `fd59:2881:fdab:1::/64` | Ping to the border router's address in it |
|---|---|---|
| `raspi-k3s2` (NetworkManager, runs Home Assistant) | yes | ok |
| `raspi-k3s` (NetworkManager) | yes | ok |
| `mini-k3s` (systemd-networkd) | yes | not tested, no `ping` |
| `ntp` (dhcpcd) | **no** | |

So `accept_ra_rt_info_max_plen` is indeed not needed on the NetworkManager and networkd
nodes. `ntp` would not reach Thread devices; nothing there needs to.

The Matter server shows two WebSocket connections from Home Assistant and 0 nodes.

## 2026-11-16: border routers on `raspi-k3s` and `raspi-k3s2`

Boards 2 and 3 flashed with the same build. They ended up in the opposite nodes from the
plan, so the overlays follow the hardware: board 3 (`3e:78`) is in `raspi-k3s`, board 2
(`40:64`) in `raspi-k3s2`. Both answered a Spinel probe on the first open after a cold
plug-in.

On each node: `60-otbr.conf` installed and loaded (IPv6 routes identical before and after),
label `thread-br=true`, Deployment applied. Both started on the first attempt.

| Node | Deployment | mDNS hostname | State |
|---|---|---|---|
| `raspi5` | `otbr-raspi5` | `raspi5-otbr` | leader |
| `raspi-k3s` | `otbr-raspi-k3s` | `raspi-k3s-otbr` | disabled, no dataset yet |
| `raspi-k3s2` | `otbr-raspi-k3s2` | `raspi-k3s2-otbr` | disabled, no dataset yet |

The Kingston USB stick that was in `raspi-k3s` is no longer attached; it was not mounted
and nothing failed.

## 2026-11-16: one Thread network on three border routers

The two new border routers were added in Home Assistant as OpenThread Border Router
integrations (`http://192.168.0.242:8081`, `http://192.168.0.241:8081`). Home Assistant gave
both the preferred dataset; it still holds exactly one dataset.

| Node | Role | RLOC16 | Extended address |
|---|---|---|---|
| `raspi5` | leader | `0x4000` | `faca7128f20509b2` |
| `raspi-k3s` | router | `0xac00` | `ce4c4b4348fc4291` |
| `raspi-k3s2` | router | `0x4800` | `be3ed0b14982d59d` |

All three: channel 15, `ha-thread-fad4`, extended PAN ID `c513a0887b2d31ee`, partition
`370331428`, identical active dataset (same SHA-256 of the TLVs), three entries in the
router table. Each advertises a default route into the mesh (`::/0 s med`); the off-mesh
prefix `fd59:2881:fdab:1::/64` is still published by `raspi5` alone.

Routes to that prefix on the LAN side, which is where the network managers differ:

| Node | Network manager | Next hops for `fd59:2881:fdab:1::/64` |
|---|---|---|
| `mini-k3s` | systemd-networkd | all three border routers |
| `raspi-k3s2` | NetworkManager 1.52 | two (the other two border routers), as one multipath route |
| `raspi-k3s` | NetworkManager 1.42 | one, `raspi5` only |
| `raspi5` | NetworkManager 1.42 | none from router advertisements; it has the direct `wpan0` route |

This is the NetworkManager limitation the Matter server documentation warns about, visible
on the two Debian 12 nodes. The Matter server currently runs on `raspi5`, so the failover
test has to show what happens to its route when the border router on `raspi5` stops.

## 2026-11-16: monitoring

- Dashboard "Thread border routers" applied as ConfigMap `thread-border-routers-dashboard`
  in `monitoring`; the Grafana sidecar wrote `thread-border-routers.json`.
- Alert group `thread` (three rules) added to `upgrade_nodes/k3s/monitoring/values.yaml`
  and rolled out with `helm upgrade` (chart 0.98.1 unchanged, revision 47 to 48), followed
  by a restart of Grafana. `helm diff` had shown the Grafana volume losing its `volumeName`;
  that is an artefact of the chart reading it with `lookup`, and the claim stayed bound.
- After one evaluation interval: `Thread;thread` holds 3 rules, 0 evaluation failures.

One alert was firing afterwards, `journald-host-missing`. It is not one of these rules and
not caused by this work: `lora-kastje` shipped its last journal line at 17:50:15 UTC, ten
minutes before this project's first command.

## 2026-11-16: Home Assistant moved to host networking

Reason: the Thread panel in Home Assistant showed "no border routers found" for the
preferred network, although all three were in the mesh and advertised `_meshcop._udp` on the
LAN (seen from the workstation). Home Assistant fills that list from mDNS, which does not
reach a pod on the cluster network. The design had left this open.

Applied: `hostNetwork: true` and `dnsPolicy: ClusterFirstWithHostNet` in
`upgrade_nodes/k3s/home-assistant/values.yaml`, Helm release `home-assistant` revision 7.
The Helm diff was those two lines in the StatefulSet and nothing else.

**It took the web UI down for about three minutes.** With host networking, Traefik reaches
Home Assistant from a node's LAN address, and Home Assistant refused it as an untrusted
proxy: every request through Home Assistant's public name answered 400. I had predicted that and added
the node addresses to `http.trusted_proxies` in `configuration.yaml` first, but Home
Assistant no longer reads that block; its HTTP settings live in `/config/.storage/http`.
Adding the addresses there and restarting the pod fixed it. The full account is in
`upgrade_nodes/k3s/home-assistant/README.md`.

Checked afterwards: 30 of 30 requests from an outside host and 30 of 30 from the LAN
answer 200; port 8123 is not reachable from outside; no untrusted-proxy lines since the
restart; the pod resolves `matter-server.thread.svc.cluster.local` and reaches the OTBR REST
API. Not checked by me: that the Thread panel now lists the border routers, which needs a
look at the UI.

Side effect: Home Assistant now sees the node's Bluetooth adapter `hci0`, which
`theengs-gateway` uses.

Confirmed by the user in the UI the same evening: the Thread panel lists three border
routers under the preferred network `ha-thread-fad4`, with unique mDNS host names:

| Shown as | Host name | Node |
|---|---|---|
| `#09B2`, with the key icon | `raspi5-otbr.local.` | `raspi5` |
| `#4291` | `raspi-k3s-otbr.local.` | `raspi-k3s` |
| `#D59D` | `raspi-k3s2-otbr.local.` | `raspi-k3s2` |

The four hex digits are the end of each router's extended address.

## 2026-11-16: the border routers talk to each other over Ethernet, not radio

Correction to an earlier conclusion. The "link quality 3" between the border routers was
read as proof that the radios reach each other between floors. It is not: all three have
TREL enabled (Thread links over the LAN), and `multiradio neighbor list` shows which link
type each neighbour uses. An average RSSI of exactly -20 is the placeholder TREL reports.

| Seen from | Neighbour | Link types | Last radio RSSI |
|---|---|---|---|
| `raspi5` | `raspi-k3s` | 15.4 and TREL | |
| `raspi5` | `raspi-k3s2` | TREL only | |
| `raspi-k3s` | `raspi5` | 15.4 and TREL | -96 dBm |
| `raspi-k3s` | `raspi-k3s2` | 15.4 and TREL | -95 dBm |
| `raspi-k3s2` | `raspi5` | TREL only | |
| `raspi-k3s2` | `raspi-k3s` | TREL only | |

So radio between floors is marginal to absent, as expected with 20 cm reinforced-concrete
floors: around -95 dBm is close to the receiver's limit. `raspi-k3s` hears both others, so
it is presumably the middle floor. What this does prove: all three radios transmit (each is
heard by at least one other over 15.4), and `raspi5` and `raspi-k3s` receive. That
`raspi-k3s2`'s radio receives is not shown by this; a Thread device on its floor will show it.

This is the reason for one border router per floor: the mesh between floors runs over
Ethernet, each radio serves its own floor.

## 2026-11-26: first devices, ten days in

Commissioned by the user through Home Assistant: seven IKEA Matter-over-Thread devices.
Read from the Matter server (`get_nodes`) and from `ot-ctl` on the border routers, 18:40 UTC.

| Node | Device | Thread role | Attached to | Status |
|---|---|---|---|---|
| 1 | TIMMERFLOTTE temp/humidity | sleepy end device | `raspi5`, child, RSSI -82 | available |
| 2 | KAJPLATS E27 bulb | router `0x8000` | radio neighbour of `raspi-k3s2`, RSSI -76 | available |
| 3 | BILRESA scroll wheel | sleepy end device | the bulb (`0x8000`) | available |
| 4 | BILRESA dual button | sleepy end device | the bulb (`0x8000`) | available |
| 5 | TIMMERFLOTTE temp/humidity | sleepy end device | `raspi-k3s`, child, RSSI -64 | available |
| 6 | GRILLPLATS plug | router at last contact | not in the mesh | **unavailable** |
| 7 | GRILLPLATS plug | REED at last contact | not in the mesh | **unavailable** |

Nodes 1 to 5 were commissioned on 21 Nov, the plugs on 25 Nov at 17:00 and 17:04. Both plugs
went offline within four seconds of each other at 17:06; node 7 came back for 14 minutes and
has been gone since 17:21. Neither has an SRP registration any more, and neither shows in any
border router's router, neighbour or child table. Cause, confirmed by the user: both plugs
were unplugged. Not a fault.

On 22 Nov from 18:13 to 18:44 nodes 2 and 3 were offline together. Node 3 uses the bulb as
its parent, so that is what a bulb losing power looks like.

Other results since the 16th:

- **No RCP trouble lines at all** from 17 Nov to now, on any border router, and 0 container
  restarts. Ten days, against the upstream report of a reset every 1-2 hours unpatched.
- **`raspi-k3s` rebooted on 20 Nov** (not by me). Its border router came back without help:
  started 14:51, rejoined as child, router again two minutes later, same partition.

## 2026-11-26: the Matter dashboard under its own name

Ingress `matter-server` in `thread`, middleware `lan-only@file`, certificate from
`letsencrypt-production` (ready in 30 s), and `PRODUCTION_MODE=true` on the Matter server so
its dashboard connects to the WebSocket at the URL it was loaded from. No login, by the user's
choice. `lan-only` also admits one external /16 range, which is not the home LAN; accepted.

Checked: from the LAN the page answers 200 with a valid certificate and `wss://.../ws`
connects; from an outside host the page answers 403 and port 5580 is closed. The Matter
server restarted for the env change: all five powered devices available again, Home Assistant
reconnected.

## 2026-11-26: Matter server 1.6.1, and OTBR container v0.5.0 on raspi-k3s2 as canary

- Backup first: `/var/lib/otbr` on `raspi-k3s2` copied to `/var/lib/otbr.bak-20261126`,
  verified identical.
- Matter server 1.6.0 to 1.6.1 (matter.js 0.18.1). All five powered devices available again
  10 s after the rollout.
- `otbr-raspi-k3s2` alone on `ghcr.io/ownbee/hass-otbr-docker:v0.5.0` (HA app 3.4.0), applied
  19:50:56 UTC. Router again within 5 s, same partition `370331428`, same RLOC16 `0x4800`,
  same extended address. otbr-agent is now `OPENTHREAD/cb18e0f` (stable v2026.10.0), against
  the unchanged RCP firmware. mDNS name, TX power 6 dBm and TREL set as before.
- **No Matter device went offline** during the border-router restart; the prediction that the
  bulb and its two remotes would drop for a few minutes was wrong. At the time `raspi5` also
  had a radio link to the bulb (`8a2a`), so the bulb was not cut off.

New log lines from v0.5.0, all harmless: `No primary trel interface found! Using eth0` (TREL_IF
is not set, eth0 is right) and `Daemon read: Connection reset by peer` (an `ot-ctl` session
closing). otbr-agent's lines no longer carry the uptime prefix.

Still to do: if `raspi-k3s2` runs a day without RCP trouble lines or restarts, move the v0.5.0
image into `k8s/otbr/base` and remove the override, which upgrades `raspi5` and `raspi-k3s`.

## 2026-11-27: all border routers on OTBR container v0.5.0

The canary on `raspi-k3s2` ran from 26 Nov 19:51 to 27 Nov 20:33 UTC with no RCP trouble lines
and no restarts. `raspi-k3s` (20:35:45) and then `raspi5` (20:36:18) moved to v0.5.0, one at
a time. Each was back as router or leader within 10 s, all three on partition `370331428`
running `OPENTHREAD/cb18e0f`, four routers in the table, and Matter nodes 1 to 5 available
throughout. The two TIMMERFLOTTE sensors that had a border router as parent re-attached
elsewhere; no border router has a child at the moment.

The backup `/var/lib/otbr.bak-20261126` on `raspi-k3s2` is still there; it can be removed.

## 2026-11-27: the Thread workloads are a Rancher App

Chart `thread` 0.1.2 from this repository's GitHub Pages site, installed by the
user from Rancher as release `thread` in namespace `thread`, revision 1, 20:43 UTC. Before
that, the seven running objects were given Helm's ownership label and annotations, so the
install adopted them: the four Deployments, and the Matter server's Service, PVC and Ingress.

Checked afterwards: every pod has the start time and restart count it had before; the live
objects equal the release manifest; the PVC is the same volume
(`pvc-9a389fca-95e9-4f19-bf46-dfdbcac3c023`) and now carries `helm.sh/resource-policy: keep`;
the three border routers are leader and routers on partition `370331428`; Matter nodes 1 to 5
are available; the dashboard's name answers 200 from the LAN and 403 from outside.

## 2026-11-27: field ownership handed to Helm

The objects had been applied server-side by the field manager `kubernetes-mcp-server` before
Helm adopted them, so both managers owned every spec field. Helm 4 applies server-side without
forcing conflicts, so the first upgrade that changed a value (an image bump from Rancher) would
have failed with a conflict. Every field `kubernetes-mcp-server` owned was also owned by `helm`
(checked per object), so its `managedFields` entry was removed from each of the seven objects
with a JSON patch guarded by a `test` operation. Generations and pods unchanged; a server-side
dry run as `helm` shows no conflict. From now on these objects are changed only through the App.

## 2026-11-27: Matter server on any border-router node

Chart 0.1.4 (PR #3) selects the Matter server's node by the label `thread-br=true` instead of
the host names copied from Home Assistant. The user upgraded the App to it (release revision
2). The Matter server restarted once and landed on `raspi-k3s`, the Pi with the most free
memory; its Longhorn volume attached there, and it reaches the Thread network through that
node's own `wpan0`. Through the dashboard's WebSocket under its public name, which followed the pod: nodes 1 to
5 available; Home Assistant reconnected. No border router restarted.

## 2026-11-27: radio wrapper proven in the OTBR image

Before moving the border routers to a DaemonSet, the new container command
(`thread/files/link-radio.sh`) ran in two throwaway pods with the real image
`hass-otbr-docker:v0.5.0`, unprivileged, with a fake by-id directory:

- one fake radio: `link-radio: radio usb-Espressif_USB_JTAG_serial_debug_unit_TEST-if00 linked to
  /dev/ttyOTBR`, then s6-overlay started (`preinit`, `s6-rc: info: service ...`, the banner), so
  `/init` runs fine behind the wrapper;
- no radio: `link-radio: expected exactly one radio matching
  usb-Espressif_USB_JTAG_serial_debug_unit_*-if00 in /dev/serial/by-id, found 0`, exit 1, no s6.

Pods and ConfigMap deleted afterwards.

The same check with the Spinel probe added, in one throwaway pod on the same image
(Python 3.13.5): the probe's own tests against a fake radio on a pseudo-terminal passed, and
the wrapper refused a by-id entry that does not answer: `found 1 candidate, 0 answered`.
Pod and ConfigMap deleted.

## 2026-11-28: border routers are one DaemonSet

The user upgraded the App to chart 0.1.6 (release revision 4, values: only Rancher's `global`
block), 08:14:55 UTC. Helm replaced the three `otbr-<node>` Deployments with DaemonSet `otbr`;
its three pods started at 08:15:02 on `raspi5`, `raspi-k3s` and `raspi-k3s2`, all Ready, no
restarts. The Matter server did not restart.

Each pod probed its node's one matching device, got
`openthread-esp32/051e4c4eb20-43cc05a9b; esp32c6; ... api 11`, and linked it to `/dev/ttyOTBR`:
`3F:98` on `raspi5`, `3E:78` on `raspi-k3s`, `40:64` on `raspi-k3s2`, the same radios as
before. Roles leader, router, router on partition `370331428`; the REST API answers on all
three node addresses; Matter nodes 1 to 5 available; dashboard 200; no Thread or Matter
warnings in Home Assistant's log.

## 2026-11-28: the rolling update, measured

`kubectl -n thread rollout restart daemonset/otbr` at 08:18:46 UTC, sampled every 5 s (pod
state, and `/node/state` on each node's REST API). Order and timing:

| Node | Old pod terminating | New pod Ready |
|---|---|---|
| `raspi5` | 08:18:46 | 08:18:58 |
| `raspi-k3s2` | 08:20:01 | 08:20:07 |
| `raspi-k3s` | 08:21:10 | 08:21:16 |

One node at a time, each next node about 63 s after the previous one was Ready (the 60 s of
`minReadySeconds` plus the sampling interval). At every sample at least two border routers
reported `router` or `leader`; the lowest count was 2. The whole rollout took 3.5 minutes.
No Matter device went offline (no offline event in the Matter server's log); all three back
on partition `370331428`, `raspi5` leader again.

## 2026-11-28: chart 0.1.7, scripts in the rollout checksum

The user upgraded the App to 0.1.7 (release revision 5). The pod-template checksum now also
covers the radio scripts, so the upgrade rolled the border routers as intended, one node at a
time: `raspi5` 08:53:19, `raspi-k3s` 08:54:29, `raspi-k3s2` 08:55:40 UTC. No pod restarted on
its own, no Matter device went offline, all three back on partition `370331428`. Rancher's
upgrade waited for the whole rollout (`pending-upgrade` until the third node was Ready).

The pod template also still carries `kubectl.kubernetes.io/restartedAt` from the rollout test;
it is owned by kubectl, not Helm, and does nothing.
