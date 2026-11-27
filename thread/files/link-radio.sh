#!/bin/sh
# Container command for the border routers. Every border-router node has exactly one
# OpenThread radio, but its /dev/serial/by-id name carries that radio's MAC address and so
# differs per node. Find it by pattern, link it to one fixed path that DEVICE names, and hand
# over to the image's own entrypoint, so s6-overlay's /init stays PID 1.
#
# Anything other than exactly one radio stops the container before otbr-agent starts, with
# the count in the log: no radio means it is unplugged, two means a second board went into
# this node by mistake.
set -eu
dir="${RADIO_DIR:-/dev/serial/by-id}"
pattern="${RADIO_PATTERN:-usb-Espressif_USB_JTAG_serial_debug_unit_*-if00}"
link="${RADIO_LINK:-/dev/ttyOTBR}"

count=0
found=""
for entry in "$dir"/$pattern; do
    # A by-id entry is a symlink into /dev; count it even if its target is missing.
    if [ -e "$entry" ] || [ -L "$entry" ]; then
        count=$((count + 1))
        found="$entry"
    fi
done
if [ "$count" -ne 1 ]; then
    echo "link-radio: expected exactly one radio matching $pattern in $dir, found $count" >&2
    exit 1
fi
ln -sf "$found" "$link"
echo "link-radio: radio $(basename "$found") linked to $link"

if [ "$#" -eq 0 ]; then
    set -- /init
fi
exec "$@"
