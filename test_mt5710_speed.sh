#!/bin/bash

set -u

INTERFACE="${1:-usb1}"
PING_TARGET="${PING_TARGET:-223.5.5.5}"
TEST_SIZE_MB="${TEST_SIZE_MB:-50}"
IPERF_SERVER="${IPERF_SERVER:-}"
IPERF_PORT="${IPERF_PORT:-5201}"
SERVERS=(36663 5396 16204 43752)

# 国内镜像，使用 HTTP Range 只下载指定大小，不写入磁盘。
DEFAULT_TEST_URLS="
https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/22.04.5/ubuntu-22.04.5-live-server-amd64.iso
https://mirrors.huaweicloud.com/ubuntu-releases/22.04.5/ubuntu-22.04.5-live-server-amd64.iso
"
TEST_URLS="${TEST_URL:-$DEFAULT_TEST_URLS}"

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "错误：找不到 5G 接口 $INTERFACE。" >&2
    echo "请先确认 MT5710 已拨号：systemctl status mt5710-5g-connect.service --no-pager" >&2
    exit 1
fi

if ! ip -4 addr show "$INTERFACE" | grep -q 'inet '; then
    echo "错误：$INTERFACE 没有 IPv4 地址。" >&2
    echo "可尝试重新拨号：systemctl restart mt5710-5g-connect.service" >&2
    exit 1
fi

echo "MT5710 5G 测速"
echo "============="
echo "接口: $INTERFACE"
echo "IPv4: $(ip -4 -br addr show "$INTERFACE" | awk '{print $3}')"
echo "默认路由: $(ip route | awk '/^default/ {print; exit}')"
echo

if ! ip route get "$PING_TARGET" 2>/dev/null | grep -q "dev $INTERFACE"; then
    echo "错误：公网流量没有走 $INTERFACE，停止测速以免测到其他网卡。" >&2
    ip route get "$PING_TARGET" >&2
    exit 2
fi

echo "1. 延迟测试：$PING_TARGET"
ping -c 5 -W 3 "$PING_TARGET" || {
    echo "错误：ping 测试失败，请检查 5G 网络。" >&2
    exit 2
}

echo
echo "2. 吞吐测速"

# 与 4G 的 /root/test_speed.sh 使用相同的 Ookla 国内服务器。
# 逐台重试，避免某个运营商测速节点临时不可达。
if command -v speedtest >/dev/null 2>&1; then
    for SERVER in "${SERVERS[@]}"; do
        echo "尝试 Ookla Speedtest 国内服务器：$SERVER"
        if speedtest --accept-license --accept-gdpr -I "$INTERFACE" --server-id="$SERVER"; then
            exit 0
        fi
        echo "服务器 $SERVER 测试失败，自动尝试下一台……" >&2
    done
    echo "Ookla 国内服务器均不可用，改用国内镜像下载测速。" >&2
fi

# iperf3 需要另一台机器启动服务端：iperf3 -s
if [ -n "$IPERF_SERVER" ]; then
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo "错误：设置了 IPERF_SERVER，但系统没有 iperf3。" >&2
        exit 3
    fi
    echo "使用现成的 iperf3：$IPERF_SERVER:$IPERF_PORT"
    iperf3 -c "$IPERF_SERVER" -p "$IPERF_PORT" -B "$(ip -4 -o addr show "$INTERFACE" | awk '{split($4,a,"/"); print a[1]; exit}')"
    exit $?
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "错误：系统没有 curl。可执行：apt-get update && apt-get install -y curl" >&2
    exit 3
fi

case "$TEST_SIZE_MB" in
    ''|*[!0-9]*) echo "错误：TEST_SIZE_MB 必须为正整数。" >&2; exit 4 ;;
    0) echo "错误：TEST_SIZE_MB 必须大于 0。" >&2; exit 4 ;;
esac

LAST_BYTE=$((TEST_SIZE_MB * 1024 * 1024 - 1))
ERR_FILE="$(mktemp /tmp/mt5710-speed-curl.XXXXXX)"
trap 'rm -f "$ERR_FILE"' EXIT

SUCCESS=0
for URL in $TEST_URLS; do
    echo "国内下载源: $URL"
    RESULT="$(curl -4 --interface "$INTERFACE" --location \
        --range "0-$LAST_BYTE" --connect-timeout 10 --max-time 120 \
        --output /dev/null --silent --show-error \
        --write-out '%{http_code} %{size_download} %{speed_download}' \
        "$URL" 2>"$ERR_FILE")"
    CURL_STATUS=$?
    HTTP_CODE="$(printf '%s' "$RESULT" | awk '{print $1}')"
    BYTES="$(printf '%s' "$RESULT" | awk '{print $2}')"
    BYTES_PER_SEC="$(printf '%s' "$RESULT" | awk '{print $3}')"

    if [ "$CURL_STATUS" -eq 0 ] && [ "$HTTP_CODE" = "206" ] && \
       awk -v n="${BYTES:-0}" 'BEGIN { exit !(n > 0) }'; then
        awk -v bps="$BYTES_PER_SEC" -v bytes="$BYTES" 'BEGIN {
            printf "下载数据: %.2f MiB\n", bytes / 1024 / 1024
            printf "下载速度: %.2f Mbps (%.2f MiB/s)\n", bps * 8 / 1000 / 1000, bps / 1024 / 1024
        }'
        SUCCESS=1
        break
    fi

    echo "此源失败（curl=$CURL_STATUS, HTTP=$HTTP_CODE），尝试下一个国内源。" >&2
    sed -n '1,3p' "$ERR_FILE" >&2
done

if [ "$SUCCESS" -ne 1 ]; then
    echo "错误：所有国内下载源均测速失败。" >&2
    exit 5
fi

echo
echo "3. 国内 HTTP 连通性"
curl -4 --interface "$INTERFACE" --silent --show-error --max-time 12 \
    --output /dev/null --write-out '百度 HTTP %{http_code}，连接 %{time_connect}s，总计 %{time_total}s\n' \
    https://www.baidu.com/
