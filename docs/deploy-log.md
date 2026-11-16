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
