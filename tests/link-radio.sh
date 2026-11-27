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
cat > "$tmp/probe" <<'STUB'
#!/bin/sh
grep -qxF "$(basename "$1")" "$RADIO_TEST_ANSWERS" 2>/dev/null && { echo "openthread-esp32/test api 11"; exit 0; }
echo "no answer"; exit 1
STUB
chmod +x "$tmp/probe"
run() {
    RADIO_DIR="$tmp/case/by-id" RADIO_LINK="$tmp/case/ttyOTBR" RADIO_PROBE="$tmp/probe" \
        RADIO_TEST_ANSWERS="$tmp/case/answers" sh "$script" true > "$tmp/case/out" 2>&1
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
