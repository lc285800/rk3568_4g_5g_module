#!/bin/bash
set -u

AT_PORT="${MT5710_AT_PORT:-/dev/ttyUSB1}"
INTERFACE="${MT5710_INTERFACE:-usb1}"
LOCK_FILE=/run/lock/mt5710-at.lock

if [ ! -c "$AT_PORT" ]; then
    echo "status=offline reason=missing_at_port port=$AT_PORT"
    exit 1
fi

exec 9>"$LOCK_FILE"
if ! flock -w 10 9; then
    echo "status=busy reason=at_port_locked"
    exit 2
fi

python3 - "$AT_PORT" "$INTERFACE" <<'PY'
import os
import select
import subprocess
import sys
import termios
import time

port, interface = sys.argv[1:3]
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

def drain(seconds):
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

def send(command):
    os.write(fd, command.encode() + b"\r")
    return drain(1.6)

try:
    attrs = termios.tcgetattr(fd)
    attrs[0] = attrs[1] = attrs[3] = 0
    attrs[2] = termios.B115200 | termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[4] = attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    drain(0.5)
    os.write(fd, b"+++")
    drain(2.5)

    responses = {}
    for command in ("AT+COPS?", "AT+C5GREG?", "AT^SYSINFOEX", "AT^HCSQ?"):
        responses[command] = send(command)

    def result(prefix):
        for text in responses.values():
            for line in text.splitlines():
                line = line.strip()
                if line.startswith(prefix):
                    return line
        return "missing"

    cops = result("+COPS:")
    reg5g = result("+C5GREG:")
    sysinfo = result("^SYSINFOEX:")
    hcsq = result("^HCSQ:")
    address = subprocess.run(
        ["ip", "-4", "-o", "addr", "show", "dev", interface, "scope", "global"],
        text=True, capture_output=True
    ).stdout.strip()
    ping = subprocess.run(
        ["ping", "-c", "1", "-W", "3", "223.5.5.5"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode == 0

    registered = ",1," in reg5g or ",5," in reg5g
    nr = '"NR"' in hcsq or '"NR-5GC"' in sysinfo
    online = registered and nr and bool(address) and ping
    print(
        f"status={'online' if online else 'degraded'} "
        f"operator={cops!r} 5g_registration={reg5g!r} "
        f"system={sysinfo!r} signal={hcsq!r} "
        f"ipv4={address!r} ping={'ok' if ping else 'failed'}"
    )
    raise SystemExit(0 if online else 1)
finally:
    os.close(fd)
PY
