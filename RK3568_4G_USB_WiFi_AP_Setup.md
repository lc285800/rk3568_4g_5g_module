# RK3568：4G 上网共享到 USB Wi-Fi AP 的配置说明

## 1. 目标与当前结果

目标链路：

```mermaid
flowchart LR
    Phone["手机/电脑"] -->|"Wi-Fi: RK3568-4G"| WLAN["wlan0 / 10.42.0.1"]
    WLAN -->|"DHCP + DNS + NAT"| NM["NetworkManager shared"]
    NM -->|"默认路由 metric 20"| PPP["ppp0"]
    PPP --> Modem["Quectel 4G / APN ctnet"]
    Modem --> Internet["互联网"]
```

当前板卡已经实现：

- Quectel 4G 模块拨号联网；
- Realtek USB Wi-Fi 从驱动盘模式自动切换为无线网卡模式；
- `wlan0` 工作在 2.4 GHz AP 模式；
- 手机通过 DHCP 获得 `10.42.0.x` 地址；
- NetworkManager 自动完成 DNS 转发、IPv4 转发和 NAT；
- 4G、Wi-Fi 模式切换和 AP 均支持开机自动启动。

## 2. 当前软硬件信息

| 项目 | 当前值 |
|---|---|
| 开发板 | RK3568 / LubanCat |
| 系统 | Ubuntu 20.04.6 LTS, aarch64 |
| 内核 | Linux 4.19.232 |
| 4G 模块 | Quectel `2c7c:6002` |
| 运营商/APN | 中国电信，`ctnet` |
| 当前 4G 数据接口 | `ppp0` |
| USB Wi-Fi 初始模式 | `0bda:1a2b`，Realtek DISK |
| USB Wi-Fi 工作模式 | `0bda:c820`，Realtek 802.11ac NIC |
| Wi-Fi 驱动 | `rtl8821cu` / `8821cu.ko` |
| AP 接口 | `wlan0` |
| 热点 SSID | `RK3568-4G` |
| 热点密码 | `rk3568wifi`（测试密码，正式部署应修改） |
| AP 地址 | `10.42.0.1/24` |
| DHCP 地址池 | `10.42.0.10` ～ `10.42.0.254` |
| Wi-Fi 频段 | 2.4 GHz，信道 6，20 MHz |

当前经过验证的 USB 结构：

```text
Quectel 2c7c:6002
├── cdc_ether  -> usb1（ECM 接口，目前不是主数据链路）
└── option     -> ttyUSB0/1/2（拨号与 AT 串口）

Realtek 0bda:c820
├── rtl8821cu  -> wlan0
└── btusb      -> 蓝牙接口
```

## 3. 原理说明：为什么最初显示为 Flash/ROM

该 Realtek USB Wi-Fi 上电后先以 `0bda:1a2b` 枚举，产品名称为 `DISK`，接口类型是 USB Mass Storage。它的用途类似 Windows 驱动盘，并不代表需要给网卡刷固件。

Linux 需要对这个存储接口发送标准弹出命令。设备断开后会以 `0bda:c820` 重新枚举，此时 `rtl8821cu` 驱动才能绑定并创建 `wlan0`。

模式变化如下：

```text
0bda:1a2b / Realtek DISK / usb-storage
        |
        | usb_modeswitch -KW
        v
0bda:c820 / Realtek 802.11ac NIC / rtl8821cu
        |
        v
wlan0
```

这一步是 USB mode switch，不是刷 ROM。

## 4. 安装所需工具

```bash
apt-get update
apt-get install -y \
  usb-modeswitch usb-modeswitch-data \
  network-manager dnsmasq-base \
  iw iptables
```

检查 NetworkManager：

```bash
systemctl enable --now NetworkManager
systemctl is-active NetworkManager
```

## 5. 将 USB Wi-Fi 从 DISK 切换为 Wi-Fi

### 5.1 确认初始状态

```bash
lsusb
lsusb -t
iw dev
```

初始状态会看到：

```text
ID 0bda:1a2b Realtek Semiconductor Corp.
Product: DISK
Driver=usb-storage
```

此时通常没有 `wlan0`。

### 5.2 手动切换

```bash
usb_modeswitch -KW -v 0bda -p 1a2b
sleep 4
lsusb
ip -br link
```

成功后应看到：

```text
ID 0bda:c820 Realtek Semiconductor Corp.
wlan0
```

`-K`/`-W` 最终使用的是标准存储设备 EJECT 流程。设备重新枚举后，内核中的驱动会自动加载。必要时可手动加载：

```bash
modprobe 8821cu
```

确认驱动和 AP 能力：

```bash
lsmod | grep 8821cu
modinfo 8821cu | grep -E 'filename|version|0BDApC820'
iw list | sed -n '/Supported interface modes:/,/Band /p'
```

输出中必须包含：

```text
* AP
```

本机驱动位置：

```text
/lib/modules/4.19.232/kernel/drivers/net/wireless/rockchip_wlan/rtl8821cu/8821cu.ko
```

### 5.3 开机自动切换

系统自带 `/lib/udev/rules.d/40-usb_modeswitch.rules`，其中已有：

```udev
ATTR{idVendor}=="0bda", ATTR{idProduct}=="1a2b", RUN+="usb_modeswitch '/%k'"
```

为了处理板卡启动阶段 USB 枚举早于用户空间服务的情况，当前系统还增加了一个兜底 oneshot 服务：

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

systemctl daemon-reload
systemctl enable --now realtek-usb-wifi-switch.service
systemctl is-enabled realtek-usb-wifi-switch.service
```

oneshot 服务执行成功后显示 `inactive (dead)` 是正常现象；关键是退出码为 0 且服务处于 `enabled`。

## 6. 配置 4G 主链路

### 6.1 当前采用 GSM/PPP

当前实际联网链路是：

```text
NetworkManager: lubancat-4g-gsm
ttyUSB2 -> ppp0 -> 4G 网络
APN: ctnet
默认路由 metric: 20
DNS: 223.5.5.5, 114.114.114.114
```

创建配置：

```bash
nmcli connection add \
  type gsm \
  ifname '*' \
  con-name lubancat-4g-gsm \
  apn ctnet

nmcli connection modify lubancat-4g-gsm \
  connection.autoconnect yes \
  ipv4.method auto \
  ipv4.route-metric 20 \
  ipv4.ignore-auto-dns yes \
  ipv4.dns '223.5.5.5,114.114.114.114' \
  ipv6.method ignore

nmcli connection up lubancat-4g-gsm
```

如果配置已经存在，不要重复执行 `connection add`，只需执行 `connection modify` 和 `connection up`。

检查：

```bash
nmcli -f DEVICE,TYPE,STATE,CONNECTION device
ip -br addr show ppp0
ip route
resolvectl status ppp0
ip route get 223.5.5.5
ping -c 4 www.baidu.com
```

当前正确的默认路由应类似：

```text
default dev ppp0 proto static scope link metric 20
```

### 6.2 ECM 接口说明

Quectel 同时提供 `cdc_ether` 接口 `usb1`，系统中保留了 `lubancat-4g-ecm` 配置，地址通常为 `192.168.43.100/24`。

本板重启后曾同时出现 PPP 和 ECM 默认路由，且失效的 ECM 路由 metric 50 抢走 DNS 流量。最终通过把有效 PPP 路由设为 metric 20 解决：

```text
ppp0 metric 20  -> 主链路
usb1 metric 50  -> 次级接口
```

部署时建议只自动启动一种 4G 方式。如果确定长期使用 PPP，可关闭 ECM 配置的自动连接：

```bash
nmcli connection modify lubancat-4g-ecm connection.autoconnect no
```

如果确定使用 ECM，则应关闭 PPP 自动连接，并先验证 `usb1` 能直接访问互联网：

```bash
nmcli connection modify lubancat-4g-gsm connection.autoconnect no
nmcli connection up lubancat-4g-ecm
curl --interface usb1 -4 --max-time 15 http://www.baidu.com/ -o /dev/null
```

不要让两套方式以相同优先级同时抢默认路由。

## 7. 创建 USB Wi-Fi AP

### 7.1 创建热点配置

```bash
nmcli connection add \
  type wifi \
  ifname wlan0 \
  con-name rk3568-4g-hotspot \
  autoconnect yes \
  ssid RK3568-4G

nmcli connection modify rk3568-4g-hotspot \
  802-11-wireless.mode ap \
  802-11-wireless.band bg \
  802-11-wireless.channel 6 \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.psk rk3568wifi \
  ipv4.method shared \
  ipv4.addresses 10.42.0.1/24 \
  ipv6.method ignore \
  connection.autoconnect yes \
  connection.autoconnect-priority 100

nmcli connection up rk3568-4g-hotspot
```

如果配置已经存在：

```bash
nmcli connection up rk3568-4g-hotspot
```

修改热点密码示例：

```bash
nmcli connection modify rk3568-4g-hotspot wifi-sec.psk '替换为至少8位的新密码'
nmcli connection down rk3568-4g-hotspot
nmcli connection up rk3568-4g-hotspot
```

### 7.2 `ipv4.method shared` 自动完成的工作

NetworkManager shared 模式会自动：

1. 给 `wlan0` 配置 `10.42.0.1/24`；
2. 启动专用于 `wlan0` 的 dnsmasq；
3. 提供 DHCP，当前地址池为 `10.42.0.10` ～ `10.42.0.254`；
4. 提供 DNS 转发；
5. 设置 `/proc/sys/net/ipv4/ip_forward=1`；
6. 添加 NAT MASQUERADE，使 `10.42.0.0/24` 走系统默认路由上网。

当前 NAT 规则：

```iptables
-A POSTROUTING -s 10.42.0.0/24 ! -d 10.42.0.0/24 -j MASQUERADE
```

因为规则根据系统默认路由工作，所以主链路为 `ppp0` 时，热点客户端会自动经 `ppp0` 出口上网。

## 8. 完整验证流程

### 8.1 USB Wi-Fi 与 AP

```bash
lsusb -d 0bda:c820
lsmod | grep 8821cu
ip -br link show wlan0
iw dev wlan0 info
nmcli -f DEVICE,TYPE,STATE,CONNECTION device
```

`iw dev wlan0 info` 应包含：

```text
ssid RK3568-4G
type AP
channel 6 (2437 MHz)
```

### 8.2 4G、路由和 DNS

```bash
ip route
ip route get 1.1.1.1
resolvectl status ppp0
ping -c 4 www.baidu.com
```

出口应为 `ppp0`，metric 应低于其他默认路由。

### 8.3 DHCP、DNS 与 NAT

```bash
cat /proc/sys/net/ipv4/ip_forward
ss -lunp | grep -E '10.42.0.1:53|0.0.0.0:67'
iptables -t nat -S | grep '10.42.0.0/24'
cat /var/lib/NetworkManager/dnsmasq-wlan0.leases
iw dev wlan0 station dump
```

### 8.4 手机端验证

1. 手机连接 `RK3568-4G`；
2. 确认获得 `10.42.0.x` 地址；
3. 网关和 DNS 应指向 `10.42.0.1`；
4. 打开网页或执行网络测速。

## 9. 信号与速率检查

板卡已部署信号查询脚本：

```bash
/root/check_4g_signal.sh
```

输出示例：

```text
4G LTE 信号：
  RSRP : -105 dBm
  RSRQ : -7 dB
  RSSI : -94 dBm
  SINR : 12 dB
```

该脚本默认通过 AT 口 `/dev/ttyUSB1` 向移远 EC200N 发送以下指令：

```text
AT+QENG="servingcell"
```

如果模块的 AT 口发生变化，可以把设备路径作为参数传入：

```bash
/root/check_4g_signal.sh /dev/ttyUSB2
```

如需绕过脚本直接发送 AT 指令，可安装 `atinout`：

```bash
apt-get install -y atinout
```

重启后 AT 口可能在 `/dev/ttyUSB1` 或 `/dev/ttyUSB2`，可逐个尝试：

```bash
echo 'AT+QENG="servingcell"' | atinout - /dev/ttyUSB1 -
echo 'AT+QENG="servingcell"' | atinout - /dev/ttyUSB2 -
```

更换天线后，本板实测：

```text
RSRP = -97 dBm
RSRQ = -8 dB
RSSI = -90 dBm
SINR = 17 dB
```

相比旧天线的 `RSRP=-109 dBm、SINR=11 dB`，新天线有明显改善。

4G 测速建议使用 Ookla 官方 ARM64 客户端。Ubuntu 20.04 自带的 Python
`speedtest-cli 2.1.2` 会访问已经返回 HTTP 403 的旧配置接口，不应继续使用：

```bash
apt-get remove -y speedtest-cli
curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt-get update
apt-get install -y speedtest

# 首次运行，记录许可与隐私条款接受状态
speedtest --accept-license --accept-gdpr --servers

# 后续测速：绑定 4G 接口并使用当前验证可达的江苏电信服务器
speedtest -I ppp0 --server-id=36663
```

板卡已部署带链路检查和服务器自动重试功能的测速脚本，日常使用推荐直接执行：

```bash
/root/test_speed.sh
```

该脚本会先确认 `ppp0` 存在、已经获得 IPv4 地址，并验证默认流量确实经过
`ppp0`。随后依次尝试服务器 `36663`、`5396`、`16204` 和 `43752`，避免单个
测速服务器故障导致误判为 4G 断网。

曾使用北京联通服务器 `43752` 遇到以下错误：

```text
[error] Error: [101] Network unreachable
[error] Latency test failed
```

故障发生时，`ppp0`、默认路由、DNS 和普通 HTTPS 访问均正常；切换到江苏电信
服务器 `36663` 后测速成功。因此该现象是指定测速服务器从当前电信链路不可达，
不是 4G 拨号断开。不要在脚本中只固定 `43752`。

新天线后三次实测平均值约为：

```text
Ping:     31.4 ms
Download: 6.34 Mbit/s
Upload:   4.28 Mbit/s
```

Wi-Fi 局域网性能应与 4G 性能分开测试。在开发板启动服务端：

```bash
iperf3 -s
```

手机或电脑连接热点后执行：

```bash
iperf3 -c 10.42.0.1 -P 4 -t 15
iperf3 -c 10.42.0.1 -P 4 -t 15 -R
```

第一条测客户端到开发板，第二条测开发板到客户端。

## 10. 常见故障

### 10.1 `lsusb` 仍显示 `0bda:1a2b`

```bash
usb_modeswitch -KW -v 0bda -p 1a2b
sleep 4
lsusb
```

检查自动切换服务：

```bash
systemctl is-enabled realtek-usb-wifi-switch.service
journalctl -u realtek-usb-wifi-switch.service -b --no-pager
```

### 10.2 已显示 `0bda:c820`，但没有 `wlan0`

```bash
modprobe 8821cu
dmesg | grep -Ei 'c820|8821cu|wlan'
ip -br link
```

### 10.3 有 4G 地址，但域名无法解析

先区分 IP 故障和 DNS 故障：

```bash
ping -c 3 223.5.5.5
getent ahostsv4 www.baidu.com
ip route
resolvectl status
```

当前 PPP 修复命令：

```bash
nmcli connection modify lubancat-4g-gsm \
  ipv4.route-metric 20 \
  ipv4.ignore-auto-dns yes \
  ipv4.dns '223.5.5.5,114.114.114.114'

nmcli connection down lubancat-4g-gsm
nmcli connection up lubancat-4g-gsm
```

### 10.4 热点能连接但不能上网

```bash
ip route get 1.1.1.1
cat /proc/sys/net/ipv4/ip_forward
iptables -t nat -S | grep MASQUERADE
systemctl status NetworkManager --no-pager
nmcli connection up rk3568-4g-hotspot
```

重点检查：

- 4G 默认路由是否真实可用；
- `ppp0` 是否为优先默认路由；
- `wlan0` 是否为 `type AP`；
- dnsmasq 是否监听 UDP 53 和 67；
- NAT 是否存在 `10.42.0.0/24` 的 MASQUERADE 规则。

### 10.5 Speedtest 报 `Network unreachable` 或 `Latency test failed`

先检查 4G 接口和路由：

```bash
ip -br addr show ppp0
ip route
ip route get 1.1.1.1
```

如果 `ip route get` 显示 `dev ppp0`，且普通网络访问正常，则优先更换测速服务器：

```bash
speedtest -I ppp0 --server-id=36663
```

推荐直接运行带自动重试功能的脚本：

```bash
/root/test_speed.sh
```

如果 `ppp0` 不存在或没有 IPv4 地址，再重新拨号：

```bash
nmcli connection down lubancat-4g-gsm
nmcli connection up lubancat-4g-gsm
```

## 11. 最终状态速查

```bash
lsusb | grep -E '2c7c:6002|0bda:c820|0bda:1a2b'
nmcli -f DEVICE,TYPE,STATE,CONNECTION device
iw dev wlan0 info
ip -br addr
ip route
resolvectl status ppp0
cat /proc/sys/net/ipv4/ip_forward
iptables -t nat -S | grep MASQUERADE
```

期望的核心结果：

```text
USB Wi-Fi: 0bda:c820
wlan0:     AP / 10.42.0.1/24 / RK3568-4G
4G:        ppp0 / default route metric 20
DHCP/DNS:  NetworkManager dnsmasq
NAT:       10.42.0.0/24 MASQUERADE
```
