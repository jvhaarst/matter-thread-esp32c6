#!/usr/bin/env bash
# Tests for thread/files/link-radio.sh, the wrapper that finds a node's one OpenThread radio,
# links it to a fixed path and hands over to the image's /init. Runs it against temporary
# directories, with a stub in place of the Spinel probe and `true` as the command to hand over to.
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
# The probe is stubbed: it answers for device names listed in $tmp/case/answers.
# Every device it is asked about is logged to $tmp/case/probed. A name listed in
# $tmp/case/other-firmware answers as another firmware (exit 2).
cat > "$tmp/probe" <<'STUB'
#!/bin/sh
basename "$1" >> "$(dirname "$RADIO_TEST_ANSWERS")/probed"
grep -qxF "$(basename "$1")" "$RADIO_TEST_ANSWERS" 2>/dev/null && { echo "openthread-esp32/test api 11"; exit 0; }
grep -qxF "$(basename "$1")" "$(dirname "$RADIO_TEST_ANSWERS")/other-firmware" 2>/dev/null && { echo "ESPHome 2026.11.0 api None"; exit 2; }
echo "no answer"; exit 1
STUB
chmod +x "$tmp/probe"
run() {
    RADIO_DIR="$tmp/case/by-id" RADIO_LINK="$tmp/case/ttyOTBR" RADIO_PROBE="$tmp/probe" \
        RADIO_TEST_ANSWERS="$tmp/case/answers" NODE_NAME=node-a RADIO_OVERRIDES="$tmp/case/overrides" \
        sh "$script" true > "$tmp/case/out" 2>&1
}
other=usb-Espressif_USB_JTAG_serial_debug_unit_90:64:9B:AB:40:64-if00

# One radio that answers: linked, announced, and the command runs.
case_dir; touch "$tmp/case/by-id/$radio"; echo "$radio" > "$tmp/case/answers"
if run; then
    [ "$(readlink "$tmp/case/ttyOTBR")" = "$tmp/case/by-id/$radio" ] || fail "one radio: link points at $(readlink "$tmp/case/ttyOTBR")"
    grep -q "radio $radio linked to $tmp/case/ttyOTBR" "$tmp/case/out" || fail "one radio: no announcement: $(cat "$tmp/case/out")"
else
    fail "one radio: exited non-zero: $(cat "$tmp/case/out")"
fi

# Another ESP32 on the node that does not answer as OpenThread is skipped.
case_dir; touch "$tmp/case/by-id/$radio" "$tmp/case/by-id/$other"; echo "$radio" > "$tmp/case/answers"
run || fail "radio plus a silent ESP32: exited non-zero: $(cat "$tmp/case/out")"
[ "$(readlink "$tmp/case/ttyOTBR" 2>/dev/null)" = "$tmp/case/by-id/$radio" ] || fail "radio plus a silent ESP32: linked the wrong device"

# A matching device that does not answer: refuses and says so (a hung or wrongly flashed board).
case_dir; touch "$tmp/case/by-id/$radio"
if run; then fail "silent device: exited zero"; fi
grep -q "found 1 candidate, 0 answered" "$tmp/case/out" || fail "silent device: message was: $(cat "$tmp/case/out")"
[ ! -e "$tmp/case/ttyOTBR" ] || fail "silent device: a link was made"

# No candidate at all.
case_dir
if run; then fail "no radio: exited zero"; fi
grep -q "found 0 candidates, 0 answered" "$tmp/case/out" || fail "no radio: message was: $(cat "$tmp/case/out")"

# Two radios that both answer: refuses.
case_dir; touch "$tmp/case/by-id/$radio" "$tmp/case/by-id/$other"; printf '%s\n%s\n' "$radio" "$other" > "$tmp/case/answers"
if run; then fail "two answering radios: exited zero"; fi
grep -q "found 2 candidates, 2 answered" "$tmp/case/out" || fail "two answering radios: message was: $(cat "$tmp/case/out")"

# Devices that do not match the pattern are not even probed.
case_dir; touch "$tmp/case/by-id/$radio" "$tmp/case/by-id/usb-FTDI_FT232R_USB_UART_A1234-if00-port0"; echo "$radio" > "$tmp/case/answers"
run || fail "radio plus another serial device: exited non-zero: $(cat "$tmp/case/out")"
! grep -q FTDI "$tmp/case/probed" || fail "radio plus another serial device: the FTDI device was probed"

# The log tells "did not answer" from "answered as other firmware".
case_dir; touch "$tmp/case/by-id/$radio" "$tmp/case/by-id/$other"; echo "$radio" > "$tmp/case/answers"
echo "$other" > "$tmp/case/other-firmware"
run || fail "radio plus other firmware: exited non-zero: $(cat "$tmp/case/out")"
grep -q "$other: not an OpenThread radio: ESPHome" "$tmp/case/out" || fail "other firmware not reported as such: $(cat "$tmp/case/out")"
case_dir; touch "$tmp/case/by-id/$radio"
run || true
grep -q "$radio: no answer" "$tmp/case/out" || fail "a silent device is not reported as \"no answer\": $(cat "$tmp/case/out")"
! grep -q "not an OpenThread radio" "$tmp/case/out" || fail "a silent device is reported as other firmware: $(cat "$tmp/case/out")"

# Overrides exist but none for this node: say so, then discover as usual.
case_dir; touch "$tmp/case/by-id/$radio"; echo "$radio" > "$tmp/case/answers"
printf 'node-b %s\n' "$other" > "$tmp/case/overrides"
run || fail "overrides for other nodes only: exited non-zero"
grep -q "no override for node-a" "$tmp/case/out" || fail "missing \"no override for node-a\": $(cat "$tmp/case/out")"

# An override names this node's radio: it is used even when another radio also answers.
case_dir; touch "$tmp/case/by-id/$radio" "$tmp/case/by-id/$other"; printf '%s\n%s\n' "$radio" "$other" > "$tmp/case/answers"
printf 'node-a %s\n' "$other" > "$tmp/case/overrides"
run || fail "override: exited non-zero: $(cat "$tmp/case/out")"
[ "$(readlink "$tmp/case/ttyOTBR" 2>/dev/null)" = "$tmp/case/by-id/$other" ] || fail "override: linked $(readlink "$tmp/case/ttyOTBR" 2>/dev/null)"
grep -q "override for node-a" "$tmp/case/out" || fail "override: not announced: $(cat "$tmp/case/out")"

# An override for another node is ignored here.
case_dir; touch "$tmp/case/by-id/$radio"; echo "$radio" > "$tmp/case/answers"
printf 'node-b %s\n' "$other" > "$tmp/case/overrides"
run || fail "override for another node: exited non-zero: $(cat "$tmp/case/out")"

# An override naming a device that is not there: refuses, names it.
case_dir; touch "$tmp/case/by-id/$radio"; echo "$radio" > "$tmp/case/answers"
printf 'node-a %s\n' "$other" > "$tmp/case/overrides"
if run; then fail "override to a missing device: exited zero"; fi
grep -q "override for node-a: $other not found" "$tmp/case/out" || fail "override to a missing device: message was: $(cat "$tmp/case/out")"

# An overridden device must still answer as an OpenThread radio.
case_dir; touch "$tmp/case/by-id/$radio" "$tmp/case/by-id/$other"; echo "$radio" > "$tmp/case/answers"
printf 'node-a %s\n' "$other" > "$tmp/case/overrides"
if run; then fail "override to a silent device: exited zero"; fi
[ ! -e "$tmp/case/ttyOTBR" ] || fail "override to a silent device: a link was made"

# The command is handed over (exec), with its arguments.
case_dir; touch "$tmp/case/by-id/$radio"; echo "$radio" > "$tmp/case/answers"
RADIO_DIR="$tmp/case/by-id" RADIO_LINK="$tmp/case/ttyOTBR" RADIO_PROBE="$tmp/probe" RADIO_TEST_ANSWERS="$tmp/case/answers" \
    sh "$script" sh -c 'echo handed-over "$1"' x arg > "$tmp/case/out" 2>&1 || true
grep -q "handed-over arg" "$tmp/case/out" || fail "command not handed over: $(cat "$tmp/case/out")"

if [ "$failures" -gt 0 ]; then
    echo "$failures link-radio case(s) failed" >&2
    exit 1
fi
echo "PASS: link-radio.sh"
