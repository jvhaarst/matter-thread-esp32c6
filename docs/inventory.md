# Inventory, 2026-11-16

Read-only survey of the cluster and the upstream projects, taken before anything was built.

## Nodes

k3s `v1.34.11+k3s1`.

| Node | Hardware | OS | Role | Uplink | RA handled by | avahi on UDP 5353 |
|---|---|---|---|---|---|---|
| `raspi5` | Pi 5 | Debian 12 | control-plane, etcd | `eth0` | NetworkManager | yes |
| `raspi-k3s` | Pi 5 | Debian 12 | control-plane, etcd | `eth0` | NetworkManager | yes |
| `raspi-k3s2` | Pi 5 | Debian 13 | control-plane, etcd | `eth0` | NetworkManager | yes |
| `ntp` | Pi 4 | Debian 11 | worker | `eth0` | dhcpcd | yes |
| `mini-k3s` | x86_64 | Ubuntu 26.04 | worker | `eno1` | systemd-networkd | no |

On every node: `net.ipv6.conf.<uplink>.accept_ra = 0`, `accept_ra_rt_info_max_plen = 0`,
`net.ipv6.conf.all.forwarding = 0`, `net.ipv4.ip_forward = 1`. `/dev/net/tun` exists and the
`cdc-acm` module is available on all four Pis. WiFi is down on all Pis.

Although the kernel ignores router advertisements, the nodes do learn routes from Route
Information Options: each has `2001:4c3c:3d00:700::/56 via fe80::de15:c8ff:fe58:be0 proto ra`.
The network manager installs them in userspace. That is why
`accept_ra_rt_info_max_plen` is not part of this project.

## LAN

- IPv4 `192.168.0.0/24`, router `192.168.0.1` (FritzBox).
- IPv6 by SLAAC: global `2001:4c3c:3d00:700::/64` and unique-local `fdfd:1cb8:52e7::/64`.

## Home Assistant

Helm release `home-assistant` (chart `pajikos/home-assistant` 0.3.91), namespace
`home-assistant`, StatefulSet, image `2026.11.1`, pod network with `dnsPolicy: ClusterFirst`,
15Gi Longhorn volume, node affinity `raspi5` or `raspi-k3s2`, running on `raspi-k3s2`. Its
values and upgrade notes live in `upgrade_nodes/k3s/home-assistant/`.

No Matter server, no border router and no Zigbee coordinator in the cluster.

## Radios

Three Seeed Studio XIAO ESP32-C6, onboard antenna. None plugged into a node yet.

| # | Base MAC | Node |
|---|---|---|
| 1 | `90:64:9b:ab:3f:98` | `raspi5`, flashed 2026-11-16 |
| 2 | `90:64:9b:ab:40:64` | `raspi-k3s2`, flashed 2026-11-16 |
| 3 | `90:64:9b:ab:3e:78` | `raspi-k3s`, flashed 2026-11-16 |

## Node configuration

By hand over SSH, documented in the `upgrade_nodes` repository. Ansible is planned there
but not built.

## Upstream versions

| Component | Version | OpenThread | Spinel RCP API |
|---|---|---|---|
| ESP-IDF | v6.1.1 (2026-11-16) | `43cc05a9bc` (2026-07-22) | 11 |
| ESP-IDF | v5.5.6 (2026-10-16) | `43cc05a9bc` | 11 |
| ESP-IDF | v6.0.3 (2026-09-02) | `b678a4f63b` (2026-07-04) | 11 |
| HA OTBR app 3.4.0, stable | ot-br-posix `cb4bdae242` (2026-09-30) | `cb18e0f598` (2026-09-25) | 11 |
| HA OTBR app 3.4.0, beta | ot-br-posix `76fb21d666` (2026-10-31) | `ecd308b4a0` (2026-10-26) | 12 |
| `ownbee/hass-otbr-docker` v0.4.0 (2026-10-13) | built on add-on image 3.3.0, otbr-agent `0.3.0-fd872ab9` | `2a8b4a5` (read from `ot-ctl version`) | works with RCP API 11 |
| `matter-js/matterjs-server` | v1.6.0 (2026-11-14) | | |

OpenThread now defines `SPINEL_MIN_HOST_SUPPORTED_RCP_API_VERSION` (4), so host and radio
no longer need the same API version, only a radio at or above the host's minimum.

## What changed against the earlier research

- **RCP over USB is not fixed in any release.** esp-idf#18490, #19343 and #17432 are open.
  Espressif announced a driver-level fix on 2026-11-09; it has not shipped.
- **The OTBR add-on moved** to `home-assistant/app-openthread-border-router`.
- **`python-matter-server` is archived.** Its replacement runs unprivileged, listens on 5580,
  and probes the OTBR REST API on port 8081 (`--thread-rest-probe-port`).
- **The sysctl advice does not fit these nodes**, see above.
- **NetworkManager and multiple border routers:** the Matter server documentation says no
  released NetworkManager handles several routes to the same prefix properly.
