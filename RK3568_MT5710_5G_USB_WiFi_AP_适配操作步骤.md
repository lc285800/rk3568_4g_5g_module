# RK3568 / 鲁班猫2：MT5710 5G 模块 + USB Wi-Fi 热点适配操作步骤

> 适用硬件：鲁班猫2 / RK3568，TD Tech MT5710-CN 5G RedCap 模块，
> Realtek USB Wi-Fi。本文以 Ubuntu 20.04、Linux 4.19.232 为例。
> 以下命令默认在板卡上以 `root` 用户执行。

## 1. 目标链路

最终目标是让板卡通过 MT5710 5G 模块上网，并继续把网络共享给 USB Wi-Fi 热点。

```text
手机/电脑
  -> Wi-Fi 热点 wlan0 / 10.42.0.1
  -> NetworkManager shared + NAT
  -> MT5710 NCM 网卡 usb1
  -> 5G 网络 / 互联网
```

本次实测成功状态：

```text
MT5710 USB ID: 3466:3301
模块型号: MT5710_CN
固件版本: V100R001C00B108
USB 模式: AT^SETMODE? -> ^SETMODE:4
拨号方式: Linux NCM + AT^NDISDUP=1,1
AT/PCUI 口: /dev/ttyUSB1
5G 数据网卡: usb1
APN: ctnet
DNS: 223.5.5.5, 114.114.114.114
旧 4G GSM 配置: lubancat-4g-gsm 已禁用自动连接
ModemManager: 已禁用，避免抢占 MT5710 AT 口
开机服务: mt5710-5g-connect.service
```

## 2. 准备硬件

1. 断开板卡电源。
2. 插入 MT5710 5G 模块、SIM 卡和 5G 天线。
3. 插入 USB Wi-Fi 网卡和 Wi-Fi 天线。
4. 给板卡上电。
5. 通过串口、显示器键盘或板载网口 SSH 登录板卡。

示例：

```bash
ssh root@192.168.2.130
```

确认系统：

```bash
uname -a
cat /etc/os-release
```

本次实测环境：

```text
Ubuntu 20.04.6 LTS
Linux lubancat 4.19.232 aarch64
```

### 2.1 供电要求与压力测试

RK3568 板卡、MT5710 5G 模块和 USB Wi-Fi 同时工作时，峰值电流会明显高于
空闲状态。特别是 5G 下载和上传测速时，MT5710 的瞬时发射功耗会增大。
电源标称功率不足、电源线过长过细或接头接触不良，都可能导致 5V 瞬时压降，
表现为 Wi-Fi 热点突然消失、SSH 中断、USB 设备重新枚举，甚至整板复位。

本机在使用 `5V/2A` 电源时，曾在短时间内多次出现热点断开和 SSH 掉线。
事后日志显示：

```text
系统在 21:47、21:54、22:03 附近连续重新启动
上一轮日志没有正常 shutdown/reboot 过程
system.journal 报 corrupted or uncleanly shut down
SSH 会话被标记为 gone - no logout / crash
无 OOM、过热、磁盘空间不足或单独的 Wi-Fi 服务崩溃证据
```

这类日志特征说明不只是 Wi-Fi 客户端掉线，而是整板发生了非正常复位或掉电。
将电源更换为质量可靠的 `5V/3A` 后，于 2026-07-14 进行了以下压力测试：

```text
连续 10 轮 MT5710 5G 测速
每轮包含公网 Ping、满负荷下载和上传
下载约 28-35 Mbps，上传约 7-9 Mbps
10/10 轮返回成功，Ping 无丢包
启动 ID 全程不变，系统未重启
usb1 和 wlan0 全程保持 UP/LOWER_UP
温度由约 52°C 上升到最高约 56.1°C
无新的 USB disconnect、watchdog、OOM、过热、复位或电压错误日志
```

因此，当出现“运行 5G 测速时热点和 SSH 一起掉线”时，应优先排查供电，
不要只重启 NetworkManager 或更换 Wi-Fi 配置。

建议：

1. 当前这套硬件实测 `5V/3A` 可稳定运行，不建议再使用 `5V/2A`。
2. 量产、长时间满载或外接更多 USB 设备时，建议使用 `5V/4A` 至 `5V/5A` 电源留出余量。
3. 使用短、粗、质量可靠的电源线，并检查插头、转接板和地线。
4. 如果 MT5710 由 USB 取电且仍有掉线，可改为独立供电，或使用带独立电源的 USB Hub。
5. 软件日志只能辅助判断。若要捕捉毫秒级压降，应在测速时用示波器监测板卡输入端和 USB 5V。

`5V/3A` 压力测试通过只能证明当前硬件和当前网络条件下稳定，不等于对所有外设、
信号强度和环境温度的绝对保证。

### 2.2 MT5710 天线接口和选型

这一步非常关键。MT5710 能拨号不代表天线合适，天线接口扣得上也不代表频段合适。
本次低速率和弱信号排查中，天线是最需要优先确认的硬件项。

#### 2.2.1 先确认模块封装

MT5710 不同封装对应的天线座不一样：

```text
MT5710 Mini PCIe 封装: IPEX 一代 / U.FL / MHF1
MT5710 M.2 封装:      IPEX 四代 / MHF4
```

本次使用的是 PCIe/Mini PCIe 封装，因此应选择：

```text
接口: IPEX 一代，或标注 U.FL / MHF1
阻抗: 50Ω
数量: 至少 2 根，分别接 MAIN 和 DIV
频段: 优先 600-6000MHz 全频段 4G/5G 蜂窝天线
```

不要给 Mini PCIe 封装买 `IPEX 四代 / MHF4` 天线。IPEX 一代和四代是不同尺寸的
射频扣座，正常情况下不能互扣；强行按压可能造成模块座子或天线端子变形。

#### 2.2.2 和 EC200N 4G 模块的关系

如果手里的天线可以正常扣在移远 EC200N Mini PCIe 4G 模块上，又可以正常扣在
MT5710 Mini PCIe 模块上，那么接口大概率是 IPEX 一代 / U.FL / MHF1。

但是要注意：这只能说明机械接口基本匹配，不能说明天线频段适合 5G 蜂窝网络。
例如 Intel 7265D 笔记本无线网卡配套的天线，通常是 Wi-Fi / Bluetooth 天线，
主要面向 2.4GHz 和 5GHz Wi-Fi 频段；它能扣上 MT5710，并不代表它适合 LTE/NR
蜂窝频段，尤其不代表低频和运营商 5G 频段性能合格。

#### 2.2.3 购买天线时按这个标准筛选

推荐搜索关键词：

```text
IPEX一代 5G天线 600-6000MHz
U.FL 5G全频天线 600-6000MHz
MHF1 4G 5G 蜂窝天线 50Ω
```

优先选择商品参数里明确写了以下信息的天线：

```text
接口: IPEX一代 / U.FL / MHF1
频段: 600-6000MHz，或至少覆盖 698-960 / 1710-2700 / 3300-3800MHz
阻抗: 50Ω
用途: 4G/5G 蜂窝模块、物联网模块、LTE/NR 模块
线长: 够用即可，线越长损耗越大
数量: 买 2 根相同规格，MAIN 和 DIV 都要接
```

尽量避开以下描述：

```text
仅标注 2.4G / 5.8G / Wi-Fi / 蓝牙
仅标注 IPEX四代 / MHF4
只写 5G WiFi，而不是 5G 蜂窝 / LTE / NR
没有频段范围、没有接口类型、没有 50Ω 参数
```

如果商品标题写“5G 模块天线 IPEX 四代”，但当前模块是 MT5710 Mini PCIe，那么这类
天线不适合直接购买。除非商品选项里可以明确选择 `IPEX 一代 / U.FL / MHF1`。

#### 2.2.4 天线接法和现场验证

MT5710 Mini PCIe 模块有两路天线接口：

```text
MAIN / ANT_MAIN: 主天线，必须接
DIV / ANT_DIV:   分集天线，建议接
```

两根天线尽量分开放置，避免贴在金属外壳、屏蔽罩、电源线、USB3.0 线缆旁边。
如果安装在机箱里，优先考虑外置 SMA 天线，使用 `IPEX一代/U.FL -> SMA` 转接线。

上电后可运行天线信号脚本：

```bash
/root/check_mt5710_antenna.sh
```

本次实测曾出现类似结果：

```text
整体 RSRP: -104 dBm
整体 RSRQ: -10 dB
整体 SINR: 17 dB
天线0 RSRP: -104.25 dBm, SINR: 16.625 dB
天线1 RSRP: -113.0 dBm,  SINR: 7.875 dB
```

这说明两路天线都被模块识别到了，但第二路明显更弱。排查方法：

1. 断电。
2. 交换 MAIN 和 DIV 两根天线。
3. 上电后再次运行 `/root/check_mt5710_antenna.sh`。

判断方法：

```text
弱信号跟着某一根天线走: 天线本体、馈线或端子可能有问题。
弱信号固定在某个模块接口: 模块接口、扣座、板卡布局或附近干扰可能有问题。
两路都弱: 天线频段不合适、摆放位置差，或当前位置 5G 覆盖弱。
```

常见参考值：

```text
RSRP -80 dBm 左右: 很好
RSRP -90 dBm 左右: 可用且较好
RSRP -100 dBm 左右: 偏弱
RSRP -105 dBm 或更差: 弱信号，速率容易明显下降
SINR 15 dB 以上: 较好
SINR 5-10 dB: 一般
SINR 0 dB 附近或负数: 干扰大或信号很差
```

## 3. 安装所需软件

如果是新板卡，先让板载网口临时联网，然后安装工具：

```bash
apt-get update
apt-get install -y \
  network-manager ppp \
  usbutils curl \
  dnsmasq-base iw iptables
```

NetworkManager 需要继续用于 Wi-Fi 热点：

```bash
systemctl enable --now NetworkManager
systemctl is-active NetworkManager
```

## 4. 检查 MT5710 USB 枚举

查看 USB 设备：

```bash
lsusb
```

应看到：

```text
ID 3466:3301 TD Tech Ltd. TDTECH MT571X
```

查看 USB 接口和驱动绑定：

```bash
lsusb -t
```

正常 NCM 模式下会看到类似：

```text
Bus 02.Port 1: Dev 2, If 0, Class=Communications, Driver=cdc_ncm
Bus 02.Port 1: Dev 2, If 1, Class=CDC Data, Driver=cdc_ncm
Bus 02.Port 1: Dev 2, If 2, Class=Vendor Specific Class, Driver=option
Bus 02.Port 1: Dev 2, If 3, Class=Vendor Specific Class, Driver=option
Bus 02.Port 1: Dev 2, If 4, Class=Vendor Specific Class, Driver=option
Bus 02.Port 1: Dev 2, If 5, Class=Vendor Specific Class, Driver=option
```

查看网卡：

```bash
ip -br link
```

应看到 MT5710 的 NCM 网卡，例如：

```text
usb1 DOWN 62:e5:41:6a:b2:a9 <NO-CARRIER,BROADCAST,MULTICAST,UP>
```

此时 `usb1` 还没有 carrier 是正常的，因为还没有下发 NCM 拨号命令。

## 5. 绑定 MT5710 串口

如果没有 `/dev/ttyUSB*`，先加载驱动并把 MT5710 VID/PID 加入 `option` 驱动：

```bash
modprobe cdc_ncm
modprobe option
modprobe usbserial

echo "3466 3301" > /sys/bus/usb-serial/drivers/option1/new_id
sleep 2
ls -l /dev/ttyUSB*
```

正常应出现：

```text
/dev/ttyUSB0
/dev/ttyUSB1
/dev/ttyUSB2
/dev/ttyUSB3
```

本次板卡上端口对应关系：

```text
ttyUSB0 -> Application Interface
ttyUSB1 -> PCUI Interface，AT 控制口
ttyUSB2 -> SerialC
ttyUSB3 -> GPS Interface
```

也可以用 sysfs 确认：

```bash
for t in /sys/bus/usb-serial/devices/ttyUSB*; do
  echo "$t -> $(readlink -f "$t")"
done
```

## 6. 注意：PCUI 口可能处于数据态

本次遇到的关键问题是：`/dev/ttyUSB1` 初始不直接响应 `AT`，反而持续吐出 PPP/IP
封装数据。现象类似：

```text
~\xff}#\xc0!... 二进制数据 ...
```

这不是串口绑定失败，而是 PCUI 口处于数据态。需要先按标准逃逸流程进入 AT 命令态：

1. 保持短暂静默。
2. 向 `/dev/ttyUSB1` 发送 `+++`，不要带回车。
3. 再等待短暂静默。
4. 发送 `AT`。

成功后会看到：

```text
AT
OK
```

## 7. 手工 AT 验证

创建一个临时 Python 探测脚本：

```bash
cat >/tmp/mt5710_at_test.py <<'PY'
import os
import select
import termios
import time

port = "/dev/ttyUSB1"
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
attrs[0] = 0
attrs[1] = 0
attrs[2] = termios.B115200 | termios.CS8 | termios.CREAD | termios.CLOCAL
attrs[3] = 0
attrs[4] = termios.B115200
attrs[5] = termios.B115200
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

drain(2)
os.write(fd, b"+++")
print(drain(3).decode("utf-8", "replace"))

for cmd in [
    b"AT\r",
    b"ATI\r",
    b"AT^SETMODE?\r",
    b"AT+CPIN?\r",
    b"AT+CEREG?\r",
]:
    os.write(fd, cmd)
    data = drain(2)
    print(data.decode("utf-8", "replace").replace("\r", "\n"))

os.close(fd)
PY

python3 /tmp/mt5710_at_test.py
```

成功输出应包含：

```text
AT
OK

Manufacturer: TD Tech Ltd.
Model: MT5710_CN
Revision: V100R001C00B108

^SETMODE:4

+CPIN: READY
```

`^SETMODE:4` 表示 Linux NCM Normal 模式，适合当前方案。

## 8. 手工拨号并获取 IP

继续通过 `/dev/ttyUSB1` 下发 NCM 拨号：

```bash
cat >/tmp/mt5710_dial.py <<'PY'
import os
import select
import termios
import time

port = "/dev/ttyUSB1"
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
attrs[0] = 0
attrs[1] = 0
attrs[2] = termios.B115200 | termios.CS8 | termios.CREAD | termios.CLOCAL
attrs[3] = 0
attrs[4] = termios.B115200
attrs[5] = termios.B115200
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

def send(cmd, wait=2):
    os.write(fd, cmd + b"\r")
    data = drain(wait)
    print(data.decode("utf-8", "replace").replace("\r", "\n"))

drain(2)
os.write(fd, b"+++")
drain(3)
send(b"AT")
send(b'AT+CGDCONT=1,"IP","ctnet"')
send(b"AT^NDISDUP=1,1", 8)
os.close(fd)
PY

python3 /tmp/mt5710_dial.py
```

成功输出应包含：

```text
AT^NDISDUP=1,1
OK

^NDISSTAT: 1,1,,,"IPV4"
```

然后拉起 `usb1` 并 DHCP：

```bash
ip link set usb1 up
sleep 3
dhclient -r usb1 2>/dev/null || true
dhclient -1 usb1
```

检查地址和路由：

```bash
ip -br addr show usb1
ip route
```

成功示例：

```text
usb1 UP 10.29.57.54/8
default via 10.0.0.1 dev usb1
```

测试公网：

```bash
ping -c 3 -W 3 223.5.5.5
printf 'nameserver 223.5.5.5\nnameserver 114.114.114.114\n' > /etc/resolv.conf
getent ahostsv4 www.baidu.com | head
curl -4 --max-time 12 -I http://connectivitycheck.gstatic.com/generate_204
```

`curl` 成功时可看到：

```text
HTTP/1.1 204 No Content
```

## 9. 固化开机自动拨号

### 9.1 安装 AT 拨号脚本

创建 `/usr/local/sbin/mt5710-5g-connect.py`：

```bash
cat >/usr/local/sbin/mt5710-5g-connect.py <<'PY'
#!/usr/bin/env python3
import os
import select
import sys
import termios
import time

PORT = os.environ.get("MT5710_AT_PORT", "/dev/ttyUSB1")
APN = os.environ.get("MT5710_APN", "ctnet")

def configure_port(fd):
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.B115200 | termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    termios.tcsetattr(fd, termios.TCSANOW, attrs)

def drain(fd, seconds):
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

def send(fd, command, wait=1.0):
    os.write(fd, command + b"\r")
    return drain(fd, wait)

def main():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_port(fd)
        drain(fd, 1.5)

        os.write(fd, b"+++")
        escape = drain(fd, 2.5)
        sys.stdout.buffer.write(escape)

        transcript = b""
        for command in [
            b"AT",
            b"ATE1",
            f'AT+CGDCONT=1,"IP","{APN}"'.encode(),
            b"AT^NDISDUP=1,1",
        ]:
            transcript += send(fd, command, 2.0)

        transcript += drain(fd, 5.0)
        sys.stdout.buffer.write(transcript)
        sys.stdout.flush()

        text = transcript.decode("utf-8", "replace")
        if "^NDISSTAT: 1,1" in text or "OK" in text:
            return 0
        return 1
    finally:
        os.close(fd)

if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod 755 /usr/local/sbin/mt5710-5g-connect.py
```

### 9.2 安装连接脚本

创建 `/usr/local/sbin/mt5710-5g-connect.sh`：

```bash
cat >/usr/local/sbin/mt5710-5g-connect.sh <<'SH'
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
SH

chmod 755 /usr/local/sbin/mt5710-5g-connect.sh
```

### 9.3 安装 systemd 服务

创建 `/etc/systemd/system/mt5710-5g-connect.service`：

```bash
cat >/etc/systemd/system/mt5710-5g-connect.service <<'EOF'
[Unit]
Description=Bring up TD Tech MT5710 5G NCM connection
After=systemd-udev-settle.service NetworkManager.service
Wants=NetworkManager.service
Conflicts=ModemManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=MT5710_APN=ctnet
ExecStart=/usr/local/sbin/mt5710-5g-connect.sh

[Install]
WantedBy=multi-user.target
EOF
```

如果使用的不是电信 `ctnet`，修改：

```ini
Environment=MT5710_APN=ctnet
```

常见 APN：

```text
中国电信: ctnet
中国移动: cmnet
中国联通: 3gnet 或 wonet，按 SIM 套餐为准
```

## 10. 禁用旧 4G 和 ModemManager

如果板卡之前配置过 EC200N/Quectel 4G 的 NetworkManager GSM 连接，建议禁用旧连接：

```bash
nmcli connection modify lubancat-4g-gsm connection.autoconnect no 2>/dev/null || true
nmcli connection down lubancat-4g-gsm 2>/dev/null || true
```

禁用 ModemManager：

```bash
systemctl disable --now ModemManager || true
```

原因：本次适配中 ModemManager 会尝试探测或占用 MT5710 的串口，影响手工 AT
和自定义 NCM 拨号脚本。

## 11. 启用服务并验证

启用并立即启动：

```bash
systemctl daemon-reload
systemctl enable mt5710-5g-connect.service
systemctl restart mt5710-5g-connect.service
```

查看服务：

```bash
systemctl --no-pager --full status mt5710-5g-connect.service
```

成功示例：

```text
Active: active (exited)
ExecStart=/usr/local/sbin/mt5710-5g-connect.sh (code=exited, status=0/SUCCESS)
dhclient -1 usb1
```

查看服务日志：

```bash
journalctl -u mt5710-5g-connect.service -b --no-pager | tail -80
```

成功日志中应包含：

```text
AT+CGDCONT=1,"IP","ctnet"
OK
AT^NDISDUP=1,1
OK
^NDISSTAT: 1,1,,,"IPV4"
DHCPOFFER of 10.x.x.x from 10.0.0.1
DHCPACK of 10.x.x.x from 10.0.0.1
bound to 10.x.x.x
```

检查地址和默认路由：

```bash
ip -br addr show usb1
ip route
```

成功示例：

```text
usb1 UP 10.29.57.54/8
default via 10.0.0.1 dev usb1
```

公网测试：

```bash
ping -c 3 -W 3 223.5.5.5
getent ahostsv4 www.baidu.com | head -3
curl -4 --max-time 12 -I http://connectivitycheck.gstatic.com/generate_204
```

## 12. 验证 Wi-Fi 热点共享

如果沿用原来的 USB Wi-Fi 热点配置，检查：

```bash
ip -br addr show wlan0
nmcli -f NAME,DEVICE,TYPE,STATE,AUTOCONNECT connection show
sysctl net.ipv4.ip_forward
iptables -t nat -S
iptables -S FORWARD
```

正常应看到：

```text
wlan0 UP 10.42.0.1/24
net.ipv4.ip_forward = 1
-A POSTROUTING -s 10.42.0.0/24 ! -d 10.42.0.0/24 -j MASQUERADE
```

手机或电脑连接热点后，应获取 `10.42.0.x` 地址，并通过 MT5710 5G 出网。

## 13. 重启验证

重启板卡：

```bash
reboot
```

等板卡回来后检查：

```bash
systemctl --no-pager --full status mt5710-5g-connect.service
ip -br addr show usb1
ip route
ping -c 3 -W 3 223.5.5.5
```

本次重启验证结果：

```text
mt5710-5g-connect.service: active (exited)
^NDISSTAT: 1,1,,,"IPV4"
usb1 UP 10.29.57.54/8
default via 10.0.0.1 dev usb1
ping 223.5.5.5: 3 received, 0% packet loss
```

## 14. 本次遇到的问题和处理方法

### 14.1 `lsusb` 能看到 MT5710，但没有 `/dev/ttyUSB*`

现象：

```text
ID 3466:3301 TD Tech Ltd. TDTECH MT571X
No modems were found
ls: cannot access '/dev/ttyUSB*'
```

原因：内核没有把 MT5710 的 vendor-specific 接口绑定到 USB serial 驱动。

处理：

```bash
modprobe option
modprobe usbserial
echo "3466 3301" > /sys/bus/usb-serial/drivers/option1/new_id
```

厂商 Linux 手册中要求在 `option.c` 加入 TD Tech `0x3466` 相关匹配；运行时
`new_id` 是不重编内核的补救方式。

### 14.2 `ModemManager` 找不到 modem

现象：

```bash
mmcli -L
```

输出：

```text
No modems were found
```

说明：本方案不依赖 ModemManager，而是直接使用 MT5710 的 NCM 网卡和 AT 命令。
因此最终禁用 ModemManager。

### 14.3 `/dev/ttyUSB1` 不响应 AT，出现二进制数据

现象：向 `/dev/ttyUSB1` 发 `AT` 没有 `OK`，读取串口看到 PPP/IP 样式二进制帧。

处理：先发送 `+++` 逃逸到 AT 命令态，再发送 `AT`。成功后再下发：

```text
AT+CGDCONT=1,"IP","ctnet"
AT^NDISDUP=1,1
```

### 14.4 `usb1` 初始是 `NO-CARRIER`

现象：

```text
usb1 DOWN <NO-CARRIER,BROADCAST,MULTICAST,UP>
```

原因：NCM 网卡已枚举，但模块尚未完成 NDIS 拨号。

处理：下发 `AT^NDISDUP=1,1`，出现 `^NDISSTAT: 1,1,,,"IPV4"` 后，`usb1`
会变为 `LOWER_UP`，此时再 DHCP。

### 14.5 NetworkManager 无法直接管理 `usb1`

本次尝试过创建 `mt5710-5g-ncm` 的 NM ethernet 连接，但启动时出现：

```text
Error: device 'usb1' not compatible with connection 'mt5710-5g-ncm'
```

处理：不让 NM 管理 `usb1`，直接在服务脚本中使用：

```bash
dhclient -r usb1 2>/dev/null || true
dhclient -1 usb1
```

Wi-Fi 热点仍由 NetworkManager 管理，NAT 规则可以继续工作。

### 14.6 `pppd` 能协商但不能上网

本次测试过把 `/dev/ttyUSB1` 当 PPP 数据口使用，出现过：

```text
Could not determine local IP address
Serial line is looped back
```

结论：当前 `SETMODE:4` 是 Linux NCM 模式，不应走 PPP 方案。正确做法是：

```text
AT^NDISDUP=1,1 -> usb1 DHCP
```

### 14.7 DNS 不通

如果 IP ping 通但域名不解析，写入 DNS：

```bash
printf 'nameserver 223.5.5.5\nnameserver 114.114.114.114\n' > /etc/resolv.conf
```

固化脚本中已经包含这一步。

### 14.8 能拨号但速率很低、信号比原 4G 模块还差

现象：

```text
MT5710 已经拨号成功
usb1 能获取 10.x.x.x 地址
ping 正常
但下载速率只有几 Mbps 到二十几 Mbps
AT^HCSQ? 显示 NR RSRP 约 -105 dBm
```

这类问题不要只看“5G 模块”三个字。MT5710 是 5G RedCap 模块，理论速率、天线能力、
当前小区信号、运营商调度、测试下载源都会影响最终速率。尤其是天线不合适时，
模块能注册 5G，但吞吐会很难看。

本次排查结论：

```text
电信 SIM 卡本身不是明显限速卡，同卡在手机上可跑到 20-30 MB/s。
AT^DSAMBR 返回 4000000,4000000，单位是 kbps，不是 4 Mbps 限速。
板卡上 MT5710 的 NR RSRP 约 -104 到 -105 dBm，属于弱信号。
两路天线中，第二路比第一路弱约 6-9 dB。
当前使用的 Intel 7265D 配套天线更像 Wi-Fi/BT 天线，不是理想的 4G/5G 蜂窝天线。
```

处理顺序建议：

1. 先运行信号脚本：

```bash
/root/check_mt5710_signal.sh
/root/check_mt5710_antenna.sh
```

2. 确认当前是否真在 NR：

```text
网络制式: NR
RSRP: -105 dBm
RSRQ: -10 dB
SINR: 14-17 dB
```

3. 如果 RSRP 在 `-105 dBm` 左右，优先更换为 4G/5G 蜂窝全频天线，而不是继续调软件。
4. 如果两路天线差距很大，断电后交换 MAIN/DIV 天线，再重新测试。
5. 测速时优先使用国内大文件下载源；海外 HTTPS 测速源、证书时间异常、单线程下载都可能让结果偏低。

## 15. 常用排查命令

USB：

```bash
lsusb
lsusb -t
lsusb -v -d 3466:3301 | sed -n '/bInterfaceNumber\|bInterfaceClass\|bInterfaceSubClass\|bInterfaceProtocol\|iInterface/p'
```

串口：

```bash
ls -l /dev/ttyUSB*
cat /proc/tty/driver/usbserial
```

服务：

```bash
systemctl status mt5710-5g-connect.service --no-pager
journalctl -u mt5710-5g-connect.service -b --no-pager | tail -100
```

网络：

```bash
ip -br link
ip -br addr
ip route
dhclient -v -1 usb1
ping -c 3 -W 3 223.5.5.5
curl -4 --max-time 12 -I http://connectivitycheck.gstatic.com/generate_204
```

信号和天线：

```bash
/root/check_mt5710_signal.sh
/root/check_mt5710_antenna.sh
```

热点/NAT：

```bash
nmcli -f NAME,DEVICE,TYPE,STATE,AUTOCONNECT connection show
sysctl net.ipv4.ip_forward
iptables -t nat -S
iptables -S FORWARD
```

## 16. 最小成功标准

新板卡适配完成后，至少满足以下条件：

```text
lsusb 能看到 3466:3301 TDTECH MT571X
/dev/ttyUSB1 能通过 +++ 后响应 AT
AT^SETMODE? 返回 ^SETMODE:4
AT+CPIN? 返回 READY
AT^NDISDUP=1,1 返回 ^NDISSTAT: 1,1,,,"IPV4"
usb1 获取 10.x.x.x/8 地址
默认路由走 usb1
ping 223.5.5.5 成功
域名解析成功
Wi-Fi 热点 wlan0 仍为 10.42.0.1/24
手机连接热点后能上网
重启后 mt5710-5g-connect.service 自动成功
```
