#!/bin/sh
# Container command for the border routers. Every border-router node has exactly one
# OpenThread radio, but its /dev/serial/by-id name carries that radio's MAC address and so
# differs per node. Find the devices that match the pattern, ask each over Spinel whether it is
# an OpenThread radio (probe-radio.py), link the one that is to the fixed path DEVICE names, and
# hand over to the image's own entrypoint, so s6-overlay's /init stays PID 1.
#
# The pattern alone matches any ESP32 with native USB, whatever its firmware; the probe is what
# makes sure the board is a Thread radio and that it answers. Anything other than exactly one
# answering radio stops the container before otbr-agent starts, with each device's answer in
# the log: none means unplugged, hung or wrongly flashed; two means a second radio on this node.
set -eu
dir="${RADIO_DIR:-/dev/serial/by-id}"
pattern="${RADIO_PATTERN:-usb-Espressif_USB_JTAG_serial_debug_unit_*-if00}"
link="${RADIO_LINK:-/dev/ttyOTBR}"

probe="${RADIO_PROBE:-python3 /opt/thread/probe-radio.py}"

candidates=0
answered=0
found=""
for entry in "$dir"/$pattern; do
    # A by-id entry is a symlink into /dev; count it even if its target is missing.
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    candidates=$((candidates + 1))
    if answer="$($probe "$entry" 2>&1)"; then
        answered=$((answered + 1))
        found="$entry"
        echo "link-radio: $(basename "$entry"): $answer"
    else
        echo "link-radio: $(basename "$entry"): not an OpenThread radio: $answer"
    fi
done
if [ "$answered" -ne 1 ]; then
    noun=candidates
    [ "$candidates" -eq 1 ] && noun=candidate
    echo "link-radio: expected exactly one OpenThread radio matching $pattern in $dir," \
        "found $candidates $noun, $answered answered" >&2
    exit 1
fi
ln -sf "$found" "$link"
echo "link-radio: radio $(basename "$found") linked to $link"

if [ "$#" -eq 0 ]; then
    set -- /init
fi
exec "$@"
