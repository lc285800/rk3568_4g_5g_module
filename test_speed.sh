#!/bin/bash

set -u

INTERFACE="${1:-ppp0}"
SERVERS=(36663 5396 16204 43752)

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "错误：找不到 4G 接口 $INTERFACE。" >&2
    echo "请先执行：nmcli connection up lubancat-4g-gsm" >&2
    exit 1
fi

if ! ip -4 addr show "$INTERFACE" | grep -q 'inet '; then
    echo "错误：$INTERFACE 没有 IPv4 地址，请重新拨号：" >&2
    echo "nmcli connection down lubancat-4g-gsm" >&2
    echo "nmcli connection up lubancat-4g-gsm" >&2
    exit 1
fi

if ! ip route get 1.1.1.1 2>/dev/null | grep -q "dev $INTERFACE"; then
    echo "错误：默认流量没有走 $INTERFACE，请检查路由。" >&2
    ip route >&2
    exit 1
fi

for server in "${SERVERS[@]}"; do
    echo "尝试 Speedtest 服务器：$server"
    if speedtest -I "$INTERFACE" --server-id="$server"; then
        exit 0
    fi
    echo "服务器 $server 测试失败，自动尝试下一台……" >&2
done

echo "错误：所有测速服务器均不可用，请稍后重试。" >&2
exit 2
