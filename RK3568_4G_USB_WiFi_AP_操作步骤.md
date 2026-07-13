# RK3568 Ubuntu 20.04：4G + USB Wi-Fi 热点完整操作步骤

> 适用硬件：移远 EC200N（USB ID `2c7c:6002`）和 Realtek USB Wi-Fi
>（初始 ID `0bda:1a2b`，切换后 ID `0bda:c820`）。以下命令均在 RK3568
> 板卡上以 `root` 用户执行。

## 1. 连接硬件并进入 root 终端

1. 断开板卡电源。
2. 插入 4G 模块、SIM 卡和 4G 天线。
3. 插入 Realtek USB Wi-Fi 和 Wi-Fi 天线。
4. 给板卡上电，通过串口、显示器键盘或已有网络登录系统。
5. 切换到 `root`：

```bash
sudo -i
```

确认系统：

```bash
uname -a
cat /etc/os-release
```

## 2. 临时连接互联网并安装软件

首次安装软件时，先通过板载网口或其他临时网络让板卡能够访问互联网。

```bash
ping -c 4 223.5.5.5
```

安装所需软件：

```bash
apt-get update
apt-get install -y \
  network-manager modemmanager ppp \
  usb-modeswitch usb-modeswitch-data \
  dnsmasq-base iw iptables \
  usbutils atinout curl
```

启用服务：

```bash
systemctl enable --now NetworkManager
systemctl enable --now ModemManager
systemctl is-active NetworkManager
systemctl is-active ModemManager
```

两项均应返回：

```text
active
```

## 3. 检查 4G 模块

```bash
lsusb
ls -l /dev/ttyUSB* 2>/dev/null
mmcli -L
```

应看到类似结果：

```text
ID 2c7c:6002 Quectel Wireless Solutions Co., Ltd.
/dev/ttyUSB0
/dev/ttyUSB1
/dev/ttyUSB2
/org/freedesktop/ModemManager1/Modem/0 [Quectel] EC200N
```

查看模块状态：

```bash
mmcli -m 0
```

确认 SIM 卡已识别，模块状态不是 `failed` 或 `locked`。

## 4. 创建中国电信 4G 拨号配置

确认不存在同名配置：

```bash
nmcli connection show lubancat-4g-gsm 2>/dev/null || true
```

如果不存在，创建配置：

```bash
nmcli connection add \
  type gsm \
  ifname '*' \
  con-name lubancat-4g-gsm \
  apn ctnet
```

设置自动拨号、路由优先级和 DNS：

```bash
nmcli connection modify lubancat-4g-gsm \
  connection.autoconnect yes \
  connection.autoconnect-priority 50 \
  ipv4.method auto \
  ipv4.route-metric 20 \
  ipv4.ignore-auto-dns yes \
  ipv4.dns '223.5.5.5,114.114.114.114' \
  ipv6.method ignore
```

启动拨号：

```bash
nmcli connection up lubancat-4g-gsm
```

等待 10 秒后检查：

```bash
sleep 10
nmcli -f DEVICE,TYPE,STATE,CONNECTION device
ip -br addr show ppp0
ip route
ip route get 1.1.1.1
```

应看到：

```text
ttyUSB2  gsm  connected  lubancat-4g-gsm
default dev ppp0 ... metric 20
1.1.1.1 dev ppp0 ...
```

测试 4G 网络：

```bash
ping -c 4 223.5.5.5
getent ahostsv4 www.baidu.com
curl -4 --max-time 15 -I https://www.baidu.com/
```

## 5. 确保 ECM 接口不抢占 4G 默认路由

检查是否存在 `usb1` 的活动连接：

```bash
nmcli -f NAME,DEVICE,TYPE,AUTOCONNECT connection show
ip route
```

如果某个活动连接的 `DEVICE` 是 `usb1`，记录它的连接名称，然后执行：

```bash
nmcli connection modify '这里替换为usb1连接名称' connection.autoconnect no
nmcli connection down '这里替换为usb1连接名称'
```

例如连接名称为 `Wired connection 2`：

```bash
nmcli connection modify 'Wired connection 2' connection.autoconnect no
nmcli connection down 'Wired connection 2'
```

部分系统上 `usb1` 由外部 DHCP 程序管理：`ip route` 能看到
`usb1` 路由，但 `nmcli` 中没有 `DEVICE` 为 `usb1` 的活动连接。这种情况
不要猜测连接名称或强制关闭 USB 网卡，而是检查实际选路结果。

再次确认访问公网时使用 `ppp0`：

```bash
ip route
ip route get 1.1.1.1
```

`ip route get 1.1.1.1` 必须显示 `dev ppp0`。只要 PPP 默认路由的
metric 为 20、ECM 备用路由的 metric 更大（例如 100），即使
`ip route` 中保留了 `usb1` 默认路由，它也不会抢占 4G PPP 流量。

## 6. 将 USB Wi-Fi 从驱动盘模式切换为网卡模式

查看当前 USB ID：

```bash
lsusb | grep -Ei '0bda:1a2b|0bda:c820'
```

如果显示 `0bda:1a2b`，执行：

```bash
usb_modeswitch -KW -v 0bda -p 1a2b
sleep 4
```

检查切换结果：

```bash
lsusb | grep -Ei '0bda:1a2b|0bda:c820'
```

应看到：

```text
ID 0bda:c820 Realtek Semiconductor Corp.
```

## 7. 加载 Wi-Fi 驱动并确认 AP 能力

```bash
modprobe 8821cu
lsmod | grep 8821cu
ip -br link
iw dev
```

应出现接口：

```text
wlan0
```

确认驱动支持 AP：

```bash
iw list | sed -n '/Supported interface modes:/,/Band /p'
```

输出中必须包含：

```text
* AP
```

如果 `modprobe 8821cu` 报错，检查当前系统是否包含驱动：

```bash
find /lib/modules/$(uname -r) -name '*8821cu*.ko*'
```

找到驱动后执行：

```bash
depmod -a
modprobe 8821cu
```

## 8. 配置 USB Wi-Fi 开机自动切换

创建 systemd 服务：

```bash
tee /etc/systemd/system/realtek-usb-wifi-switch.service >/dev/null <<'EOF'
[Unit]
Description=Switch Realtek USB Wi-Fi from DISK to WLAN mode
After=systemd-udev-trigger.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 1 20); do if /usr/bin/lsusb -d 0bda:c820 | /bin/grep -q .; then exit 0; fi; if /usr/bin/lsusb -d 0bda:1a2b | /bin/grep -q .; then /usr/sbin/usb_modeswitch -KW -v 0bda -p 1a2b; exit 0; fi; /bin/sleep 1; done; exit 0'

[Install]
WantedBy=multi-user.target
EOF
```

启用服务：

```bash
systemctl daemon-reload
systemctl enable --now realtek-usb-wifi-switch.service
systemctl is-enabled realtek-usb-wifi-switch.service
```

应返回：

```text
enabled
```

## 9. 创建 Wi-Fi 热点

下面使用以下热点参数：

```text
SSID：RK3568-4G
密码：rk3568wifi
板卡热点地址：10.42.0.1
```

正式使用时，请把密码 `rk3568wifi` 替换为至少 8 位的新密码。

确认不存在同名配置：

```bash
nmcli connection show rk3568-4g-hotspot 2>/dev/null || true
```

如果不存在，创建热点：

```bash
nmcli connection add \
  type wifi \
  ifname wlan0 \
  con-name rk3568-4g-hotspot \
  autoconnect yes \
  ssid RK3568-4G
```

设置 AP、密码和共享网络：

```bash
nmcli connection modify rk3568-4g-hotspot \
  802-11-wireless.mode ap \
  802-11-wireless.band bg \
  802-11-wireless.channel 6 \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.psk 'rk3568wifi' \
  ipv4.method shared \
  ipv4.addresses 10.42.0.1/24 \
  ipv6.method ignore \
  connection.autoconnect yes \
  connection.autoconnect-priority 100
```

启动热点：

```bash
nmcli connection up rk3568-4g-hotspot
```

## 10. 检查热点、DHCP、DNS 和 NAT

```bash
nmcli -f DEVICE,TYPE,STATE,CONNECTION device
ip -br addr show wlan0
iw dev wlan0 info
cat /proc/sys/net/ipv4/ip_forward
ss -lunp | grep -E '10.42.0.1:53|0.0.0.0:67'
iptables -t nat -S | grep '10.42.0.0/24'
```

应满足：

```text
wlan0 connected rk3568-4g-hotspot
wlan0 地址为 10.42.0.1/24
iw 显示 type AP 和 ssid RK3568-4G
ip_forward 为 1
存在 UDP 53、UDP 67 和 MASQUERADE 规则
```

## 11. 用手机或电脑连接热点测试上网

1. 在手机或电脑上搜索 Wi-Fi。
2. 连接热点 `RK3568-4G`。
3. 输入密码 `rk3568wifi`。
4. 确认客户端获得 `10.42.0.x` 地址。
5. 确认网关和 DNS 为 `10.42.0.1`。
6. 打开网页测试上网。

在板卡上查看已连接客户端：

```bash
cat /var/lib/NetworkManager/dnsmasq-wlan0.leases
iw dev wlan0 station dump
```

连接热点后，可从客户端登录板卡：

```bash
ssh root@10.42.0.1
```

## 12. 重启并验证自动恢复

```bash
reboot
```

等待板卡启动完成，在手机或电脑上重新连接 `RK3568-4G`，然后登录板卡：

```bash
ssh root@10.42.0.1
```

板卡刚能 SSH 登录时，ModemManager 可能仍在等待 4G 模块注册，
`ttyUSB2` 和 `wlan0` 短暂显示未连接属于正常启动过程。建议等待
30 秒后再执行完整检查：

```bash
sleep 30
```

执行完整检查：

```bash
lsusb | grep -E '2c7c:6002|0bda:c820|0bda:1a2b'
systemctl is-active NetworkManager ModemManager
systemctl is-enabled realtek-usb-wifi-switch.service
nmcli -f DEVICE,TYPE,STATE,CONNECTION device
ip -br addr
ip route
ip route get 1.1.1.1
iw dev wlan0 info
cat /proc/sys/net/ipv4/ip_forward
iptables -t nat -S | grep MASQUERADE
ping -c 4 www.baidu.com
```

最终应达到：

```text
4G 模块：2c7c:6002
4G 拨号：ttyUSB2 / ppp0 / connected
公网有效路由：ppp0，metric 20（以 `ip route get 1.1.1.1` 为准）
USB Wi-Fi：0bda:c820
热点：wlan0 / RK3568-4G / 10.42.0.1/24
客户端：能够获得 10.42.0.x 地址并访问互联网
```

## 13. 连接失败时按顺序恢复

重新启动 4G 拨号：

```bash
nmcli connection down lubancat-4g-gsm
nmcli connection up lubancat-4g-gsm
sleep 10
ip route get 1.1.1.1
ping -c 4 223.5.5.5
```

重新切换并加载 USB Wi-Fi：

```bash
usb_modeswitch -KW -v 0bda -p 1a2b || true
sleep 4
modprobe 8821cu
ip -br link show wlan0
```

重新启动热点：

```bash
nmcli connection down rk3568-4g-hotspot
nmcli connection up rk3568-4g-hotspot
```

重新启动网络服务：

```bash
systemctl restart ModemManager
systemctl restart NetworkManager
sleep 10
nmcli connection up lubancat-4g-gsm
nmcli connection up rk3568-4g-hotspot
```

再次检查：

```bash
nmcli -f DEVICE,TYPE,STATE,CONNECTION device
ip route
iw dev wlan0 info
journalctl -u NetworkManager -b --no-pager | tail -n 100
journalctl -u ModemManager -b --no-pager | tail -n 100
```
