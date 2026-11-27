"""Ask a serial device whether it is an OpenThread radio (RCP), over Spinel.

    python3 probe-radio.py <device> [timeout seconds, default 2]

Sends Spinel PROP_VALUE_GET for NCP_VERSION and RCP_API_VERSION and prints what came back.
Exit 0: the device answered with an "openthread..." version and an RCP API version.
Exit 2: it answered, but not as an OpenThread radio (other firmware on the same chip).
Exit 1: no answer within the timeout, or the device cannot be opened.

DTR and RTS are kept low: on an ESP32's USB Serial/JTAG port they reset the chip.
Standard library only; it runs in the OTBR image before otbr-agent starts.
"""
import fcntl
import os
import select
import struct
import sys
import termios
import time

FLAG, ESCAPE = 0x7E, 0x7D
PROP_NCP_VERSION, PROP_RCP_API_VERSION = 0x02, 0xB0


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
    found = []
    for chunk in raw.split(bytes([FLAG])):
        body, escaped = bytearray(), False
        for byte in chunk:
            if escaped:
                body.append(byte ^ 0x20)
                escaped = False
            elif byte == ESCAPE:
                escaped = True
            else:
                body.append(byte)
        if len(body) >= 4 and fcs16(bytes(body[:-2])) == body[-2] | body[-1] << 8:
            found.append(bytes(body[:-2]))
    return found


def packed_uint(value):
    out = bytearray()
    while True:
        byte, value = value & 0x7F, value >> 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def unpack_uint(data):
    value = shift = used = 0
    for byte in data:
        value |= (byte & 0x7F) << shift
        shift += 7
        used += 1
        if not byte & 0x80:
            break
    return value, used


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        attrs = termios.tcgetattr(fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
    except termios.error:
        pass
    try:
        bits = struct.pack("I", termios.TIOCM_DTR | termios.TIOCM_RTS)
        fcntl.ioctl(fd, termios.TIOCMBIC, bits)
    except OSError:
        pass  # not a real serial port (a test pseudo-terminal)
    return fd


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 1
    path = sys.argv[1]
    timeout = float(sys.argv[2]) if len(sys.argv) == 3 else 2.0
    try:
        fd = open_port(path)
    except OSError as error:
        print(f"cannot open {path}: {error.strerror}")
        return 1

    version = api = None
    try:
        os.write(fd, bytes([FLAG]))
        os.write(fd, hdlc(bytes([0x81, 0x02]) + packed_uint(PROP_NCP_VERSION)))
        os.write(fd, hdlc(bytes([0x82, 0x02]) + packed_uint(PROP_RCP_API_VERSION)))
        raw = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and (version is None or api is None):
            ready, _, _ = select.select([fd], [], [], 0.1)
            if not ready:
                continue
            try:
                raw += os.read(fd, 512)
            except OSError:
                continue
            for frame in frames(raw):
                if len(frame) < 3 or frame[1] != 0x06:
                    continue
                prop, used = unpack_uint(frame[2:])
                value = frame[2 + used:]
                if prop == PROP_NCP_VERSION:
                    version = value.split(b"\x00", 1)[0].decode(errors="replace")
                elif prop == PROP_RCP_API_VERSION and value:
                    api = unpack_uint(value)[0]
    finally:
        os.close(fd)

    if version is None and api is None:
        print("no answer")
        return 1
    print(f"{version} api {api}")
    if version is not None and version.lower().startswith("openthread") and api is not None:
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
