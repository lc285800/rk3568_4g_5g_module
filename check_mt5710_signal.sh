#!/bin/bash

set -u

AT_PORT="${1:-/dev/ttyUSB1}"
BAUD="${BAUD:-115200}"

if [ ! -c "$AT_PORT" ]; then
    echo "错误：找不到 MT5710 AT 串口 $AT_PORT" >&2
    echo "可用串口：" >&2
    ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null >&2 || true
    exit 1
fi

python3 - "$AT_PORT" "$BAUD" <<'PY'
import os
import select
import sys
import termios
import time

port = sys.argv[1]
baud = int(sys.argv[2])

baud_map = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}

fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

try:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = baud_map.get(baud, termios.B115200) | termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = baud_map.get(baud, termios.B115200)
    attrs[5] = baud_map.get(baud, termios.B115200)
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

    def drain(seconds):
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

    def send(cmd, wait=1.2):
        os.write(fd, cmd.encode() + b"\r")
        return drain(wait).decode("utf-8", "replace").replace("\r", "\n")

    drain(1.0)
    os.write(fd, b"+++")
    drain(2.5)

    commands = [
        "AT",
        "AT^HCSQ?",
    ]
    raw = ""
    for cmd in commands:
        raw += f"\n# {cmd}\n"
        raw += send(cmd, 1.8 if cmd != "AT^MONSC" else 2.5)

    def find_line(prefix):
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith(prefix):
                return line
        return ""

    hcsq = find_line("^HCSQ:")
    if not hcsq:
        print("读取失败：没有收到 ^HCSQ 信号质量返回。", file=sys.stderr)
        sys.exit(2)

    parts = [p.strip().strip('"') for p in hcsq.split(":", 1)[1].split(",")]
    mode = parts[0] if parts else ""
    values = []
    for p in parts[1:]:
        try:
            values.append(int(p))
        except ValueError:
            pass

    print("MT5710 信号质量")
    print(f"网络制式: {mode}")

    if mode == "NR" and len(values) >= 3:
        rsrp = values[0] - 141 if values[0] != 255 else None
        sinr = (values[1] - 101) / 5 if values[1] != 255 else None
        rsrq = values[2] - 40 if values[2] != 255 else None
        print(f"RSRP: {rsrp if rsrp is not None else '无效'} dBm")
        print(f"RSRQ: {rsrq if rsrq is not None else '无效'} dB")
        print(f"SINR: {sinr if sinr is not None else '无效'} dB")
    elif mode == "LTE" and len(values) >= 4:
        rssi = values[0] - 121 if values[0] != 255 else None
        rsrp = values[1] - 141 if values[1] != 255 else None
        sinr = (values[2] - 101) / 5 if values[2] != 255 else None
        rsrq = (values[3] - 40) / 2 if values[3] != 255 else None
        print(f"RSSI: {rssi if rssi is not None else '无效'} dBm")
        print(f"RSRP: {rsrp if rsrp is not None else '无效'} dBm")
        print(f"RSRQ: {rsrq if rsrq is not None else '无效'} dB")
        print(f"SINR: {sinr if sinr is not None else '无效'} dB")
    else:
        print(f"读取失败：不支持的 HCSQ 返回：{hcsq}", file=sys.stderr)
        sys.exit(2)
finally:
    os.close(fd)
PY
