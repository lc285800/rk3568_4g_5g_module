#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
APN="${MT5710_APN:-ctnet}"
INTERFACE="${MT5710_INTERFACE:-usb1}"
AT_PORT="${MT5710_AT_PORT:-/dev/ttyUSB1}"
CHECK_INTERVAL="${MT5710_CHECK_INTERVAL:-20}"
FAILURE_LIMIT="${MT5710_FAILURE_LIMIT:-3}"
RETRY_DELAY="${MT5710_RETRY_DELAY:-15}"
PING_TARGETS="${MT5710_PING_TARGETS:-223.5.5.5 114.114.114.114}"

log()
{
    echo "$(date '+%F %T') mt5710-watchdog: $*"
}

modprobe cdc_ncm 2>/dev/null || true
modprobe option 2>/dev/null || true
modprobe usbserial 2>/dev/null || true

ensure_serial_binding()
{
    if lsusb -d 3466:3301 >/dev/null 2>&1 &&
        ! ls /dev/ttyUSB* >/dev/null 2>&1 &&
        [ -w /sys/bus/usb-serial/drivers/option1/new_id ]; then
        log "binding MT5710 serial interfaces to option driver"
        echo "3466 3301" > /sys/bus/usb-serial/drivers/option1/new_id 2>/dev/null || true
        sleep 2
    fi
}

wait_for_devices()
{
    count=0
    while [ ! -c "$AT_PORT" ] || [ ! -d "/sys/class/net/$INTERFACE" ]; do
        ensure_serial_binding
        count=$((count + 1))
        if [ "$count" -eq 1 ] || [ $((count % 10)) -eq 0 ]; then
            log "waiting for $AT_PORT and $INTERFACE"
        fi
        sleep 2
    done
}

has_carrier()
{
    [ -r "/sys/class/net/$INTERFACE/carrier" ] &&
        [ "$(cat "/sys/class/net/$INTERFACE/carrier" 2>/dev/null)" = "1" ]
}

has_ipv4()
{
    ip -4 -o addr show dev "$INTERFACE" scope global 2>/dev/null | grep -q 'inet '
}

can_reach_network()
{
    for target in $PING_TARGETS; do
        if ip route get "$target" 2>/dev/null | grep -q "dev $INTERFACE" &&
            ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

connect_modem()
{
    wait_for_devices
    log "starting NCM dial (APN=$APN, interface=$INTERFACE)"

    MT5710_AT_PORT="$AT_PORT" MT5710_APN="$APN" \
        /usr/local/sbin/mt5710-5g-connect.py || {
            log "AT dial command failed"
            return 1
        }

    ip link set "$INTERFACE" up || return 1
    sleep 3

    dhclient -r "$INTERFACE" >/dev/null 2>&1 || true
    if ! timeout 45 dhclient -1 -v "$INTERFACE"; then
        log "DHCP failed on $INTERFACE"
        return 1
    fi

    if ! has_carrier || ! has_ipv4; then
        log "dial completed without carrier or IPv4 address"
        return 1
    fi

    printf 'nameserver 223.5.5.5\nnameserver 114.114.114.114\n' > /etc/resolv.conf
    log "connection ready: $(ip -4 -o addr show dev "$INTERFACE" scope global)"
    return 0
}

# On service startup, reconnect immediately if the link is not already healthy.
# After a healthy check, transient runtime failures still require FAILURE_LIMIT hits.
failure_count=$((FAILURE_LIMIT - 1))

while :; do
    if has_carrier && has_ipv4 && can_reach_network; then
        failure_count=0
        sleep "$CHECK_INTERVAL"
        continue
    fi

    failure_count=$((failure_count + 1))
    carrier="$(cat "/sys/class/net/$INTERFACE/carrier" 2>/dev/null || echo missing)"
    ipv4="$(has_ipv4 && echo yes || echo no)"
    log "health check failed ($failure_count/$FAILURE_LIMIT): carrier=$carrier, ipv4=$ipv4"

    if [ "$failure_count" -lt "$FAILURE_LIMIT" ]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    failure_count=0
    if connect_modem; then
        sleep "$CHECK_INTERVAL"
    else
        log "reconnect failed; retrying in ${RETRY_DELAY}s"
        sleep "$RETRY_DELAY"
    fi
done
