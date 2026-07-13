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

    def send(command, wait=2.0):
        os.write(fd, command.encode() + b"\r")
        return drain(wait).decode("utf-8", "replace").replace("\r", "\n")

    drain(1.0)
    os.write(fd, b"+++")
    drain(2.5)

    raw = ""
    for command in ["AT", "AT^HCSQ?", "AT^ANTRSSI?"]:
        raw += send(command, 2.5)

    hcsq = ""
    antrssi = ""
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("^HCSQ:"):
            hcsq = line
        elif line.startswith("^ANTRSSI:"):
            antrssi = line

    if not antrssi:
        print("读取失败：没有收到 ^ANTRSSI 天线信号返回。", file=sys.stderr)
        print("原始返回：", file=sys.stderr)
        print(raw.strip(), file=sys.stderr)
        sys.exit(2)

    print("MT5710 天线信号")
    print("================")

    if hcsq:
        parts = [p.strip().strip('"') for p in hcsq.split(":", 1)[1].split(",")]
        mode = parts[0] if parts else ""
        values = []
        for p in parts[1:]:
            try:
                values.append(int(p))
            except ValueError:
                pass

        print(f"整体网络制式: {mode}")
        if mode == "NR" and len(values) >= 3:
            rsrp = values[0] - 141 if values[0] != 255 else None
            sinr = (values[1] - 101) / 5 if values[1] != 255 else None
            rsrq = values[2] - 40 if values[2] != 255 else None
            print(f"整体 RSRP: {rsrp if rsrp is not None else '无效'} dBm")
            print(f"整体 RSRQ: {rsrq if rsrq is not None else '无效'} dB")
            print(f"整体 SINR: {sinr if sinr is not None else '无效'} dB")
        print()

    fields = [p.strip() for p in antrssi.split(":", 1)[1].split(",")]
    try:
        rat = int(fields[0], 0)
        ant_count = int(fields[1], 0)
    except (ValueError, IndexError):
        print(f"解析失败：{antrssi}", file=sys.stderr)
        sys.exit(2)

    print(f"天线数量: {ant_count}")
    print(f"RAT: {'NR' if rat == 6 else rat}")

    rxlevels = fields[2:6]
    sinrs = fields[6:10]

    for index in range(min(ant_count, 4)):
        try:
            rx_raw = int(rxlevels[index], 0)
        except (ValueError, IndexError):
            rx_raw = 32767

        try:
            sinr_raw = int(sinrs[index], 0)
        except (ValueError, IndexError):
            sinr_raw = 32767

        rsrp = None if rx_raw == 32767 else rx_raw / 8
        sinr = None if sinr_raw == 32767 else sinr_raw / 8

        print()
        print(f"天线{index}:")
        print(f"  RSRP: {rsrp if rsrp is not None else '无效'} dBm")
        print(f"  SINR: {sinr if sinr is not None else '无效'} dB")

    print()
    print("判断参考:")
    print("  RSRP 越接近 0 越好，例如 -90 dBm 通常明显好于 -105 dBm。")
    print("  SINR 越大越好，10 dB 以上可用，20 dB 以上较好。")
finally:
    os.close(fd)
PY
