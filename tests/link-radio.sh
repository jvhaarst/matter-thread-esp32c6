#!/usr/bin/env bash
# Tests for thread/files/link-radio.sh, the wrapper that finds a node's one radio, links it to
# a fixed path and hands over to the image's /init. Runs it against temporary directories with
# `true` as the command to hand over to.
#
# Run from anywhere: tests/link-radio.sh
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/thread/files/link-radio.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
radio=usb-Espressif_USB_JTAG_serial_debug_unit_90:64:9B:AB:3F:98-if00

case_dir() { rm -rf "$tmp/case"; mkdir -p "$tmp/case/by-id"; }
run() { RADIO_DIR="$tmp/case/by-id" RADIO_LINK="$tmp/case/ttyOTBR" sh "$script" true > "$tmp/case/out" 2>&1; }

# One radio: linked, announced, and the command runs.
case_dir; touch "$tmp/case/by-id/$radio"
if run; then
    [ "$(readlink "$tmp/case/ttyOTBR")" = "$tmp/case/by-id/$radio" ] || fail "one radio: link points at $(readlink "$tmp/case/ttyOTBR")"
    grep -q "radio $radio linked to $tmp/case/ttyOTBR" "$tmp/case/out" || fail "one radio: no announcement: $(cat "$tmp/case/out")"
else
    fail "one radio: exited non-zero: $(cat "$tmp/case/out")"
fi

# A by-id entry is a symlink into /dev; a dangling one (radio gone) must still be counted.
case_dir; ln -s /nonexistent/ttyACM9 "$tmp/case/by-id/$radio"
run || fail "one dangling radio link: exited non-zero: $(cat "$tmp/case/out")"

# No radio: refuses, names the count, does not hand over.
case_dir
if run; then fail "no radio: exited zero"; fi
grep -q "found 0" "$tmp/case/out" || fail "no radio: message was: $(cat "$tmp/case/out")"
[ ! -e "$tmp/case/ttyOTBR" ] || fail "no radio: a link was made"

# Two radios: refuses, names the count.
case_dir; touch "$tmp/case/by-id/$radio" "$tmp/case/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_90:64:9B:AB:40:64-if00"
if run; then fail "two radios: exited zero"; fi
grep -q "found 2" "$tmp/case/out" || fail "two radios: message was: $(cat "$tmp/case/out")"

# Other serial devices on the node do not count.
case_dir; touch "$tmp/case/by-id/$radio" "$tmp/case/by-id/usb-FTDI_FT232R_USB_UART_A1234-if00-port0"
run || fail "one radio plus another device: exited non-zero: $(cat "$tmp/case/out")"

# The command is handed over (exec), with its arguments.
case_dir; touch "$tmp/case/by-id/$radio"
RADIO_DIR="$tmp/case/by-id" RADIO_LINK="$tmp/case/ttyOTBR" sh "$script" sh -c 'echo handed-over "$1"' x arg > "$tmp/case/out" 2>&1 || true
grep -q "handed-over arg" "$tmp/case/out" || fail "command not handed over: $(cat "$tmp/case/out")"

if [ "$failures" -gt 0 ]; then
    echo "$failures link-radio case(s) failed" >&2
    exit 1
fi
echo "PASS: link-radio.sh"
