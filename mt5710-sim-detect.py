#!/usr/bin/env python3
import os
import select
import sys
import termios
import time


PORT = os.environ.get("MT5710_AT_PORT", "/dev/ttyUSB1")
OUTPUT = "/run/mt5710-detected-profile"
PROFILES = {
    "46015": ("broadnet", "cbnet"),
    "46003": ("telecom", "ctnet"),
    "46005": ("telecom", "ctnet"),
    "46011": ("telecom", "ctnet"),
    "46012": ("telecom", "ctnet"),
}


def drain(fd, seconds):
    end = time.time() + seconds
    output = b""
    while time.time() < end:
        readable, _, _ = select.select([fd], [], [], 0.2)
        if readable:
            try:
                output += os.read(fd, 4096)
            except BlockingIOError:
                pass
    return output.decode("utf-8", "replace").replace("\r", "")


def query_imsi():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        attrs = termios.tcgetattr(fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.B115200 | termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[4] = attrs[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, attrs)

        drain(fd, 0.5)
        os.write(fd, b"+++")
        drain(fd, 2.5)
        os.write(fd, b"AT+CIMI\r")
        response = drain(fd, 2.5)
        for line in response.splitlines():
            line = line.strip()
            if line.isdigit() and 14 <= len(line) <= 16:
                return line
        raise RuntimeError(f"no IMSI in response: {response!r}")
    finally:
        os.close(fd)


def main():
    imsi = query_imsi()
    for prefix, (operator, apn) in PROFILES.items():
        if imsi.startswith(prefix):
            temporary = OUTPUT + ".tmp"
            with open(temporary, "w", encoding="ascii") as profile:
                profile.write(f"MT5710_OPERATOR={operator}\n")
                profile.write(f"MT5710_APN={apn}\n")
                profile.write(f"MT5710_IMSI_PREFIX={prefix}\n")
            os.replace(temporary, OUTPUT)
            print(f"detected operator={operator} imsi_prefix={prefix} apn={apn}")
            return 0
    print(f"unsupported SIM IMSI prefix: {imsi[:5]}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
