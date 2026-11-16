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
