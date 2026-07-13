#!/bin/bash

set -u

AT_PORT="${1:-/dev/ttyUSB1}"
BAUD="${BAUD:-115200}"
CAPTURE_FILE="$(mktemp /tmp/4g-signal.XXXXXX)"

cleanup() {
    rm -f "$CAPTURE_FILE"
}
trap cleanup EXIT INT TERM

if [ ! -c "$AT_PORT" ]; then
    echo "错误：找不到 AT 串口 $AT_PORT" >&2
    echo "可用串口：" >&2
    ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null >&2 || true
    exit 1
fi

stty -F "$AT_PORT" "$BAUD" raw -echo 2>/dev/null || true

timeout 4 cat "$AT_PORT" >"$CAPTURE_FILE" 2>/dev/null &
READER_PID=$!
sleep 0.3
printf 'AT+QENG="servingcell"\r' >"$AT_PORT"
wait "$READER_PID" 2>/dev/null || true

QENG_LINE="$(tr -d '\000\r' <"$CAPTURE_FILE" | grep '+QENG:.*LTE' | head -n 1 || true)"

if [ -z "$QENG_LINE" ]; then
    echo "读取失败：未收到 LTE serving cell 信息，请稍后重试。" >&2
    exit 2
fi

VALUES="$(printf '%s\n' "$QENG_LINE" | awk -F',' '{
    for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
    printf "%s %s %s %s", $14, $15, $16, $17
}')"
read -r RSRP RSRQ RSSI SINR <<<"$VALUES"

echo "4G LTE 信号："
echo "  RSRP : ${RSRP} dBm"
echo "  RSRQ : ${RSRQ} dB"
echo "  RSSI : ${RSSI} dBm"
echo "  SINR : ${SINR} dB"
echo
echo "原始返回："
echo "$QENG_LINE"
