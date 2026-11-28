"""Tests for thread/files/probe-radio.py against a fake radio on a pseudo-terminal.

Run: python3 -I tests/probe-radio-test.py
"""
import os
import subprocess
import sys
import threading
import time
import tty

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "..", "thread", "files", "probe-radio.py")
FLAG, ESCAPE = 0x7E, 0x7D


def fcs16(data):
    fcs = 0xFFFF
    for byte in data:
        fcs ^= byte
        for _ in range(8):
            fcs = (fcs >> 1) ^ 0x8408 if fcs & 1 else fcs >> 1
    return fcs ^ 0xFFFF


def hdlc(payload):
    fcs = fcs16(payload)
    out = bytearray([FLAG])
    for byte in payload + bytes([fcs & 0xFF, fcs >> 8]):
        out += bytes([ESCAPE, byte ^ 0x20]) if byte in (0x7E, 0x7D, 0x11, 0x13, 0xF8) else bytes([byte])
    return bytes(out + bytes([FLAG]))


def frames(raw):
    out = []
    for chunk in raw.split(bytes([FLAG])):
        body, esc = bytearray(), False
        for byte in chunk:
            if esc:
                body.append(byte ^ 0x20)
                esc = False
            elif byte == ESCAPE:
                esc = True
            else:
                body.append(byte)
        if len(body) >= 4 and fcs16(bytes(body[:-2])) == body[-2] | body[-1] << 8:
            out.append(bytes(body[:-2]))
    return out


def fake_radio(fd, version, api, stop, noise=b"", split=False):
    """Answer PROP_VALUE_GET for NCP_VERSION (0x02) and RCP_API_VERSION (0xB0, packed as 0xB0 0x01).

    noise is written before the first answer (boot output on the same port); split writes each
    answer in two parts with a pause, so the probe sees it across reads.
    """
    buf = b""
    if noise:
        os.write(fd, noise)
    while not stop.is_set():
        try:
            buf += os.read(fd, 256)
        except OSError:
            return
        for frame in frames(buf):
            header, command, prop = frame[0], frame[1], frame[2:]
            if command != 0x02:
                continue
            reply = None
            if prop == b"\x02" and version is not None:
                reply = hdlc(bytes([header, 0x06, 0x02]) + version.encode("latin-1") + b"\x00")
            elif prop == b"\xb0\x01" and api is not None:
                reply = hdlc(bytes([header, 0x06, 0xB0, 0x01, api]))
            if reply and split:
                os.write(fd, reply[: len(reply) // 2])
                time.sleep(0.2)
                os.write(fd, reply[len(reply) // 2:])
            elif reply:
                os.write(fd, reply)
        buf = b""


def run_probe(version, api, noise=b"", split=False):
    controller, device = os.openpty()
    tty.setraw(controller)
    stop = threading.Event()
    thread = threading.Thread(target=fake_radio, args=(controller, version, api, stop, noise, split), daemon=True)
    thread.start()
    try:
        result = subprocess.run(
            [sys.executable, "-I", PROBE, os.ttyname(device), "1.5"],
            capture_output=True, text=True, timeout=20,
        )
    finally:
        stop.set()
        os.close(device)
        os.close(controller)
    return result


failures = 0


def check(name, condition, detail):
    global failures
    if not condition:
        failures += 1
        print(f"FAIL: {name}: {detail}", file=sys.stderr)


r = run_probe("openthread-esp32/051e4c4eb20-43cc05a9b; esp32c6;  2026-11-16 19:35:02 UTC", 11)
check("OpenThread radio", r.returncode == 0, f"exit {r.returncode}, out {r.stdout!r} err {r.stderr!r}")
check("OpenThread radio reports version and API", "openthread-esp32/051e4c4eb20" in r.stdout and "api 11" in r.stdout, repr(r.stdout))

r = run_probe("ESPHome 2026.11.0", 11)
check("other firmware answering", r.returncode == 2, f"exit {r.returncode}, out {r.stdout!r} err {r.stderr!r}")

r = run_probe(None, None)
check("silent device", r.returncode == 1, f"exit {r.returncode}, out {r.stdout!r} err {r.stderr!r}")
check("silent device says so", "no answer" in r.stdout + r.stderr, repr(r.stdout + r.stderr))

r = subprocess.run([sys.executable, "-I", PROBE, "/nonexistent/ttyACM9", "1"], capture_output=True, text=True, timeout=10)
check("missing device", r.returncode == 1, f"exit {r.returncode}, err {r.stderr!r}")

# Boot output before the answers, answers split across reads, and a version string with bytes
# that HDLC must escape (0x7E, 0x7D).
r = run_probe("openthread-esp32/~}escaped; esp32c6", 11, noise=b"ESP-ROM:esp32c6\r\nI (24) boot: ESP-IDF\r\n~garbage~", split=True)
check("noise, split replies, escaped bytes", r.returncode == 0, f"exit {r.returncode}, out {r.stdout!r} err {r.stderr!r}")
check("escaped bytes decoded", "openthread-esp32/~}escaped" in r.stdout, repr(r.stdout))

# A device that hangs up (unplugged after open): a clean "no answer"/"failed" line and exit 1,
# no traceback, and no busy loop that runs to the timeout.
controller, device = os.openpty()
name = os.ttyname(device)
os.close(controller)
started = time.monotonic()
r = subprocess.run([sys.executable, "-I", PROBE, name, "5"], capture_output=True, text=True, timeout=20)
elapsed = time.monotonic() - started
os.close(device)
check("hung-up device exits 1", r.returncode == 1, f"exit {r.returncode}, out {r.stdout!r} err {r.stderr!r}")
check("hung-up device: no traceback", "Traceback" not in r.stderr, r.stderr[-300:])
check("hung-up device: gives up early", elapsed < 3, f"took {elapsed:.1f} s with a 5 s timeout")

if failures:
    print(f"{failures} probe-radio case(s) failed", file=sys.stderr)
    sys.exit(1)
print("PASS: probe-radio.py")
