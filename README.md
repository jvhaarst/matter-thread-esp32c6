# matter-thread-esp32c6

Three OpenThread border routers on a k3s cluster of Raspberry Pis, one per floor, joined to
one Thread network for Matter-over-Thread devices in Home Assistant. The radios are Seeed
Studio XIAO ESP32-C6 boards running OpenThread RCP firmware, plugged into the Pis over USB.

- [`docs/design.md`](docs/design.md): what is being built and why.
- [`docs/inventory.md`](docs/inventory.md): the cluster and upstream versions as found.
- [`docs/deploy-log.md`](docs/deploy-log.md): what was applied, in order, and what went wrong.
- [`followup/README.md`](followup/README.md): what runs, what is still unproven, what to watch.
- [`firmware/`](firmware/): reproducible RCP firmware build.
- [`k8s/`](k8s/): border routers, Matter server, Grafana dashboard and alert rules.
- [`nodes/`](nodes/): the sysctl file for border-router nodes.

## Firmware

```sh
./firmware/build.sh
```

Needs `podman` or `docker`. Produces `firmware/out/ot_rcp-xiao-esp32c6.bin`, a single image
to write at offset 0, and a `.buildinfo` file recording the ESP-IDF version, the OpenThread
commit and the Spinel RCP API version it was built from.

Flash from the workstation, with the board on USB:

```sh
uvx esptool --chip esp32c6 --port /dev/cu.usbmodemXXXX write-flash 0x0 firmware/out/ot_rcp-xiao-esp32c6.bin
```

Check that a flashed board answers, before plugging it into a node:

```sh
uv run --with pyserial firmware/tools/rcp_probe.py /dev/cu.usbmodemXXXX
```
