# Design: three Thread border routers on k3s, one Thread network

Approved 2026-11-16.

## Intent

One OpenThread border router (OTBR) per floor, each on a Raspberry Pi 5 that is already a
k3s control-plane node, all joined to a single Thread network that Home Assistant uses for
Matter-over-Thread devices. A device should stay reachable when any one border router is
down.

| Node | Radio |
|---|---|
| `raspi5` | XIAO ESP32-C6 #1 |
| `raspi-k3s` | XIAO ESP32-C6 #2 |
| `raspi-k3s2` | XIAO ESP32-C6 #3 |

`ntp` (Pi 4, end-of-life Debian 11, low memory) and `mini-k3s` (x86) are not border routers.

## Non-goals

- Zigbee, or multiprotocol firmware on the same radio.
- Thread commissioning by anything other than Home Assistant.
- Changing how Home Assistant itself is deployed, unless that turns out to be required.

## Radio firmware

- ESP-IDF v6.1.1 `examples/openthread/ot_rcp`, target `esp32c6`, Spinel over the chip's
  USB Serial/JTAG port. OTBR is told 460800 baud; on USB CDC the number has no effect.
- Three patches in [`firmware/patches/`](../firmware/patches/), because RCP over
  USB Serial/JTAG is unreliable in every released ESP-IDF
  ([esp-idf#18490](https://github.com/espressif/esp-idf/issues/18490),
  [esp-idf#19343](https://github.com/espressif/esp-idf/issues/19343)):
  1. upstream PR [esp-idf#19360](https://github.com/espressif/esp-idf/pull/19360), verbatim:
     the connection monitor loses USB start-of-frame events and reports a false disconnect;
  2. Spinel frames are sent with `usb_serial_jtag_write_bytes()` instead of the console VFS
     `write()`, which drops bytes silently; ring buffers raised to 1024 bytes; `EIO` on read
     is treated as a transient host detach;
  3. the XIAO's RF switch is driven explicitly: GPIO3 low (switch enabled), GPIO14 low
     (onboard antenna).
- Built by [`firmware/build.sh`](../firmware/build.sh) inside `espressif/idf:v6.1.1` pinned
  by digest. Flashed from the workstation with `uvx esptool`.
- Drop patches 1 and 2 when Espressif ships its own driver-level fix, announced on
  2026-11-09 in esp-idf#18490.

## Border router

- Image `ghcr.io/ownbee/hass-otbr-docker` v0.4.0, pinned by digest. It repackages the Home
  Assistant OTBR add-on (3.3.0), so the REST API is the one Home Assistant is tested against.
- (Since 2026-11-27 the Deployments come from the Helm chart in `thread/`, installed as a
  Rancher App; the per-node overlays became entries in `borderRouters`.)
- One Deployment per node: a kustomize base plus one overlay per node. Each radio's
  `/dev/serial/by-id` path contains its MAC address, so the path differs per node; a
  DaemonSet would need a udev symlink on every node to hide that.
- `strategy: Recreate`, `hostNetwork: true`, node selector on `thread-br=true` and the
  hostname, `BACKBONE_IF=eth0`, REST API on port 8081, web UI off.
- State on hostPath `/var/lib/otbr`, not Longhorn: the Thread credentials belong to the
  radio on that node and must not follow a pod elsewhere.
- Privileges start at `NET_ADMIN` and `NET_RAW` with `/dev/net/tun` and the radio mounted
  from the host. `privileged: true` only if the device node cannot be opened otherwise.
- Namespace `thread`, labelled `pod-security.kubernetes.io/enforce=privileged`.

## Nodes

`net.ipv6.conf.all.forwarding=1` on the three border-router nodes, in
`/etc/sysctl.d/60-otbr.conf`. Nothing else: all nodes run with `accept_ra=0` and let
NetworkManager process router advertisements, so `accept_ra_rt_info_max_plen` has no effect
here. See [`inventory.md`](inventory.md).

## Matter server and Home Assistant

- `ghcr.io/matter-js/matterjs-server` 1.6.0, `hostNetwork: true`, `PRIMARY_INTERFACE=eth0`,
  Longhorn volume, same node affinity as Home Assistant (`raspi5`, `raspi-k3s2`).
- (Superseded on 2026-11-16: Home Assistant runs on host networking, because the Thread
  panel needs mDNS. See the deploy log.) Home Assistant stays on the pod network at first. The OTBR integrations are added by URL
  and the Matter integration points at `ws://<node>:5580/ws`. Home Assistant moves to
  `hostNetwork` only if Thread discovery in the UI needs it.
- The Thread network is formed on `raspi5`; the other two border routers get the same
  active dataset through their OTBR integration. The network is set as preferred.

## Approaches considered

| Choice | Picked | Rejected, and why |
|---|---|---|
| OTBR image | `ownbee/hass-otbr-docker` | `openthread/otbr`: no Home Assistant patches, different REST behaviour. Own build of the add-on Dockerfile: more to maintain; the fallback if ownbee stays behind. |
| Workload | one Deployment per node | DaemonSet: needs a per-node udev rule to give the radios one common path. |
| Firmware build | pinned container | Local ESP-IDF install: not reproducible, and a multi-gigabyte toolchain on the workstation. |
| Radio transport | native USB with patches | UART: the XIAO exposes no USB-UART bridge, so it would need extra hardware per node. |

## Risks to measure

- `avahi-daemon` and OTBR both bind UDP 5353 on the border-router nodes.
- NetworkManager cannot fail over between two routes to the same prefix
  ([NetworkManager#1232](https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/issues/1232)),
  which bears directly on the "stop one border router" test.
- The Matter server's documentation advises against IPv6 forwarding on its host, and its
  candidate nodes are border routers. Escape hatch: run it on `mini-k3s`.
- The exact OpenThread commit inside add-on image 3.3.0 is not yet confirmed; read it from
  the running container.

## Order of work

1. Firmware build, flash one board.
2. One OTBR on `raspi5`.
3. Matter server, Home Assistant integrations, form the network.
4. Boards two and three, same dataset.
5. Commission a device, failover tests.

Every change to the cluster, to node sysctls, or to a radio is shown first and applied only
after approval.
