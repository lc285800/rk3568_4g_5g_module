#!/bin/bash

set -u

INTERFACE="${1:-usb1}"
TEST_URL="${TEST_URL:-https://speed.cloudflare.com/__down?bytes=10000000}"
PING_TARGET="${PING_TARGET:-223.5.5.5}"

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "错误：找不到 5G 接口 $INTERFACE。" >&2
    echo "请先确认 MT5710 已拨号：systemctl status mt5710-5g-connect.service --no-pager" >&2
    exit 1
fi

if ! ip -4 addr show "$INTERFACE" | grep -q 'inet '; then
    echo "错误：$INTERFACE 没有 IPv4 地址。" >&2
    echo "可尝试重新拨号：systemctl restart mt5710-5g-connect.service" >&2
    ip -br addr show "$INTERFACE" >&2
    exit 1
fi

if ! ip route get 1.1.1.1 2>/dev/null | grep -q "dev $INTERFACE"; then
    echo "警告：默认公网流量当前不走 $INTERFACE，当前路由如下：" >&2
    ip route >&2
    echo >&2
fi

echo "MT5710 5G 测速"
echo "============="
echo "接口: $INTERFACE"
echo "IPv4: $(ip -4 -br addr show "$INTERFACE" | awk '{print $3}')"
echo "默认路由: $(ip route | awk '/^default/ {print; exit}')"
echo

echo "1. 延迟测试：$PING_TARGET"
ping -c 5 -W 3 "$PING_TARGET" || {
    echo "错误：ping 测试失败，请先检查 5G 网络。" >&2
    exit 2
}

echo
echo "2. 下载测速"

if command -v speedtest >/dev/null 2>&1; then
    echo "检测到 speedtest，优先使用 speedtest。"
    if speedtest -I "$INTERFACE"; then
        exit 0
    fi
    echo "speedtest 测试失败，自动改用 curl 下载测速。" >&2
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "错误：未安装 curl，无法测速。" >&2
    echo "安装：apt-get install -y curl" >&2
    exit 3
fi

echo "使用 curl 下载测试：$TEST_URL"
echo "提示：默认下载 10MB 数据，不保存到磁盘。"

ERR_FILE="$(mktemp /tmp/mt5710-speed-curl.XXXXXX)"
trap 'rm -f "$ERR_FILE"' EXIT

BYTES_PER_SEC="$(
    curl -4 --interface "$INTERFACE" \
        --location \
        --connect-timeout 10 \
        --max-time 60 \
        --output /dev/null \
        --silent \
        --show-error \
        --write-out '%{speed_download}' \
        "$TEST_URL" 2>"$ERR_FILE"
)"
CURL_STATUS=$?

if [ "$CURL_STATUS" -ne 0 ]; then
    echo "提示：curl 测速未完整结束，但会按已下载数据估算速度。" >&2
    sed -n '1,5p' "$ERR_FILE" >&2
fi

awk -v bps="$BYTES_PER_SEC" 'BEGIN {
    mbps = bps * 8 / 1000 / 1000
    mib = bps / 1024 / 1024
    printf "下载速度: %.2f Mbps (%.2f MiB/s)\n", mbps, mib
}'

echo
echo "3. HTTP 连通性"
curl -4 --interface "$INTERFACE" --silent --show-error --max-time 12 -I \
    http://connectivitycheck.gstatic.com/generate_204 | sed -n '1,8p'
