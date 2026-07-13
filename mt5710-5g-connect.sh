#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
APN="${MT5710_APN:-ctnet}"

modprobe cdc_ncm 2>/dev/null || true
modprobe option 2>/dev/null || true
modprobe usbserial 2>/dev/null || true

for _ in $(seq 1 20); do
    if lsusb -d 3466:3301 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if [ -e /sys/bus/usb-serial/drivers/option1/new_id ] && ! ls /dev/ttyUSB* >/dev/null 2>&1; then
    echo "3466 3301" > /sys/bus/usb-serial/drivers/option1/new_id 2>/dev/null || true
fi

for _ in $(seq 1 20); do
    [ -e /dev/ttyUSB1 ] && [ -d /sys/class/net/usb1 ] && break
    sleep 1
done

MT5710_APN="$APN" /usr/local/sbin/mt5710-5g-connect.py

ip link set usb1 up
sleep 3

dhclient -r usb1 2>/dev/null || true
dhclient -1 usb1

printf 'nameserver 223.5.5.5\nnameserver 114.114.114.114\n' > /etc/resolv.conf
