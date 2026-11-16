#!/usr/bin/env python3
"""Ask an OpenThread RCP for its version over Spinel, to prove the firmware runs.

    uv run --with pyserial firmware/tools/rcp_probe.py /dev/cu.usbmodemXXXX

Prints the NCP version string, the Spinel protocol version and the RCP API
version, and exits non-zero if the radio does not answer.
"""
import sys
import time

import serial

HDLC_FLAG = 0x7E
HDLC_ESCAPE = 0x7D
HDLC_SPECIAL = {0x7E, 0x7D, 0x11, 0x13, 0xF8}

SPINEL_HEADER = 0x81  # flag bit, interface 0, transaction id 1
CMD_PROP_VALUE_GET = 0x02
CMD_PROP_VALUE_IS = 0x06

PROPERTIES = {
    "protocol_version": 0x01,
    "ncp_version": 0x02,
    "rcp_api_version": 0xB0,
}


def fcs16(data: bytes) -> int:
    """CRC-16/X.25, the HDLC frame check sequence."""
    fcs = 0xFFFF
    for byte in data:
        fcs ^= byte
        for _ in range(8):
            fcs = (fcs >> 1) ^ 0x8408 if fcs & 1 else fcs >> 1
    return fcs ^ 0xFFFF


def encode_packed_uint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def decode_packed_uint(data: bytes) -> tuple[int, int]:
    value = shift = used = 0
    for byte in data:
        value |= (byte & 0x7F) << shift
        shift += 7
        used += 1
        if not byte & 0x80:
            break
    return value, used


def hdlc_encode(payload: bytes) -> bytes:
    fcs = fcs16(payload)
    body = payload + bytes([fcs & 0xFF, fcs >> 8])
    out = bytearray([HDLC_FLAG])
    for byte in body:
        if byte in HDLC_SPECIAL:
            out += bytes([HDLC_ESCAPE, byte ^ 0x20])
        else:
            out.append(byte)
    out.append(HDLC_FLAG)
    return bytes(out)


def hdlc_frames(raw: bytes) -> list[bytes]:
    """Return the payloads of all frames in raw whose checksum is correct."""
    frames = []
    for chunk in raw.split(bytes([HDLC_FLAG])):
        body = bytearray()
        escaped = False
        for byte in chunk:
            if escaped:
                body.append(byte ^ 0x20)
                escaped = False
            elif byte == HDLC_ESCAPE:
                escaped = True
            else:
                body.append(byte)
        if len(body) >= 4 and fcs16(bytes(body[:-2])) == body[-2] | body[-1] << 8:
            frames.append(bytes(body[:-2]))
    return frames


def get_property(port: serial.Serial, prop: int) -> bytes | None:
    port.reset_input_buffer()
    port.write(hdlc_encode(bytes([SPINEL_HEADER, CMD_PROP_VALUE_GET]) + encode_packed_uint(prop)))
    deadline = time.monotonic() + 2
    raw = b""
    while time.monotonic() < deadline:
        raw += port.read(256)
        for frame in hdlc_frames(raw):
            if len(frame) > 2 and frame[0] == SPINEL_HEADER and frame[1] == CMD_PROP_VALUE_IS:
                got, used = decode_packed_uint(frame[2:])
                if got == prop:
                    return frame[2 + used:]
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    # DTR and RTS reset an ESP32 through its USB Serial/JTAG port, so keep both low.
    port = serial.Serial()
    port.port = sys.argv[1]
    port.baudrate = 460800
    port.timeout = 0.2
    port.dtr = False
    port.rts = False
    port.open()
    time.sleep(1)

    ok = True
    with port:
        for name, prop in PROPERTIES.items():
            value = get_property(port, prop)
            if value is None:
                print(f"{name}: no answer")
                ok = False
            elif name == "ncp_version":
                print(f"{name}: {value.rstrip(bytes(1)).decode(errors='replace')}")
            elif name == "protocol_version":
                major, used = decode_packed_uint(value)
                minor, _ = decode_packed_uint(value[used:])
                print(f"{name}: {major}.{minor}")
            else:
                print(f"{name}: {decode_packed_uint(value)[0]}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
