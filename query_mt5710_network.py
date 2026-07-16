#!/usr/bin/env python3
import os
import select
import sys
import termios
import time


port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB1"
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)


def drain(seconds):
    end = time.time() + seconds
    output = b""
    while time.time() < end:
        readable, _, _ = select.select([fd], [], [], 0.2)
        if not readable:
            continue
        try:
            output += os.read(fd, 4096)
        except BlockingIOError:
            pass
    return output.decode("utf-8", "replace").replace("\r", "")


try:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.B115200 | termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    drain(1)
    os.write(fd, b"+++")
    drain(3)

    commands = [
        "AT",
        "ATI",
        "AT+CPIN?",
        "AT+CIMI",
        "AT+CCID",
        "AT+COPS?",
        "AT+CREG?",
        "AT+CEREG?",
        "AT+C5GREG?",
        "AT+CGATT?",
        "AT+CGDCONT?",
        "AT^HCSQ?",
        "AT^SYSINFOEX",
        "AT^MONSC",
        "AT^NDISSTATQRY?",
    ]
    for command in commands:
        print(f"\n### {command}")
        os.write(fd, command.encode() + b"\r")
        print(drain(2.5), end="")
finally:
    os.close(fd)
