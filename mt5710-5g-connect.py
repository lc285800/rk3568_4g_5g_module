#!/usr/bin/env python3
import os
import select
import sys
import termios
import time


PORT = os.environ.get("MT5710_AT_PORT", "/dev/ttyUSB1")
APN = os.environ.get("MT5710_APN", "ctnet")


def configure_port(fd):
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.B115200 | termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def drain(fd, seconds):
    end = time.time() + seconds
    out = b""
    while time.time() < end:
        readable, _, _ = select.select([fd], [], [], 0.2)
        if readable:
            try:
                out += os.read(fd, 4096)
            except BlockingIOError:
                pass
    return out


def send(fd, command, wait=1.0):
    os.write(fd, command + b"\r")
    return drain(fd, wait)


def main():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_port(fd)
        drain(fd, 1.5)

        os.write(fd, b"+++")
        escape = drain(fd, 2.5)
        sys.stdout.buffer.write(escape)

        transcript = b""
        for command in [
            b"AT",
            b"ATE1",
            f'AT+CGDCONT=1,"IP","{APN}"'.encode(),
            b"AT^NDISDUP=1,1",
        ]:
            transcript += send(fd, command, 2.0)

        transcript += drain(fd, 5.0)
        sys.stdout.buffer.write(transcript)
        sys.stdout.flush()

        text = transcript.decode("utf-8", "replace")
        if "^NDISSTAT: 1,1" in text or "OK" in text:
            return 0
        return 1
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
