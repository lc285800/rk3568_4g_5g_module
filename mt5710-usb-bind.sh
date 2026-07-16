#!/bin/sh
set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
VID_PID="3466:3301"

log()
{
    echo "$(date '+%F %T') mt5710-usb-bind: $*"
}

modprobe cdc_ncm
modprobe usbserial
modprobe option

count=0
while ! lsusb -d "$VID_PID" >/dev/null 2>&1; do
    count=$((count + 1))
    if [ "$count" -ge 30 ]; then
        log "MT5710 $VID_PID was not found"
        exit 1
    fi
    sleep 1
done

if ls /dev/ttyUSB* >/dev/null 2>&1; then
    log "serial ports already present"
    exit 0
fi

NEW_ID=/sys/bus/usb-serial/drivers/option1/new_id
if [ ! -w "$NEW_ID" ]; then
    log "option new_id is not writable"
    exit 1
fi

echo "3466 3301" > "$NEW_ID"

count=0
while [ ! -c /dev/ttyUSB1 ]; do
    count=$((count + 1))
    if [ "$count" -ge 15 ]; then
        log "binding completed but /dev/ttyUSB1 did not appear"
        exit 1
    fi
    sleep 1
done

log "bound $VID_PID; AT port /dev/ttyUSB1 is ready"
