# 无锡科院校园网自动登录工具

![Platform](https://img.shields.io/badge/平台-路由器%2FWindows%2FmacOS%2FLinux-green.svg)
![Firmware](https://img.shields.io/badge/路由器-OpenWrt%2FImmortalWrt-blue.svg)
![License](https://img.shields.io/badge/许可证-MIT-blue.svg)
![Version](https://img.shields.io/badge/版本-v3.1.0-orange.svg)

## 一、项目介绍

一款为 **无锡科技职业学院校园网（Dr.COM / 哆点 eportal 认证）** 打造的自动登录与断线重连方案，旨在解决校园网频繁掉线、需要反复手动登录的痛点。

项目最初是基于 C 语言的 Windows 工具（仓库自带 v3.1），现已扩展为**协议文档 + 路由器 + 电脑**多端方案：

- **路由器（OpenWrt / ImmortalWrt）**：每秒检测，断线 1~3 秒内自动重连，开机自启，每天定时重登；
- **电脑（Windows / macOS / Linux）**：提供 C 工具、Python、PowerShell 三种实现；
- **消息通知（可选）**：通过企业微信群机器人推送掉线 / 重连通知（含断线到重连耗时）。

> 本文所有账号、密码、Webhook、MAC 均已脱敏，使用时替换为你自己的信息即可。

## 二、仓库文件说明

| 文件 | 说明 |
|---|---|
| `无锡科院校园网连接脚本v3.1.c` / `.exe` | Windows C 语言版主程序（最新，含旧版 v3.0） |
| `无锡科院校园网连接脚本v1.0.bat` / `v2.0.bat` | 早期批处理版本 |
| `双击打开开机自启文件夹.c` / `.exe` | 一键打开 Windows 开机自启目录，把脚本拖入即可开机运行 |
| `README.md` | 本文档（协议分析 + 路由器 / 电脑脚本教程） |

## 三、协议原理与关键数据

### 3.1 协议原理

Dr.COM 认证本质是几个**明文 HTTP GET 接口**。浏览器点击"登录"时，会向认证服务器发送一个带参数的 GET 请求，服务器返回一段 **JSONP** 文本表示结果。还原出 **login（登录）** 和 **logout（注销）** 两个请求后，任何能发 HTTP 请求的设备都可以模拟登录，无需浏览器、无需验证码。

### 3.2 基本配置

| 项目 | 示例值 | 说明 |
|---|---|---|
| 认证服务器 IP | `10.255.254.1` | 学校认证网关 |
| 认证端口 | `801` | eportal 端口（部分学校为 80） |
| 认证路径 | `/eportal/` | 学生认证入口 |
| 账号 | `你的学号` | 学号 / 工号 |
| 运营商后缀 | `@telecom` | 电信 `@telecom`、移动 `@cmcc`、联通 `@unicom`；无运营商则留空 |
| 密码 | `你的密码` | 校园网密码 |
| WAN IP / MAC | **动态获取** | 不要写死，见下文 |

### 3.3 登录请求（GET）

```
http://10.255.254.1:801/eportal/?c=Portal&a=login
    &callback=dr1003
    &login_method=1
    &user_account=%2C0%2C<账号URL编码>
    &user_password=<密码>
    &wlan_user_ip=<WAN_IP>
    &wlan_user_mac=<WAN_MAC>
    &jsVersion=3.3.2
    &v=8980
```

完整示例（已脱敏）：

```
http://10.255.254.1:801/eportal/?c=Portal&a=login&callback=dr1003&login_method=1&user_account=%2C0%2C2025xxxxxx%40telecom&user_password=xxxxxxxx&wlan_user_ip=10.16.239.165&wlan_user_mac=D4EE07610D5B&jsVersion=3.3.2&v=8980
```

| 参数 | 含义 |
|---|---|
| `c=Portal&a=login` | 控制器 `Portal`、动作 `login` |
| `callback=dr1003` | JSONP 回调名，登录常用 `dr1003` |
| `login_method=1` | 认证方式，`1` 为普通认证 |
| `user_account=%2C0%2C账号` | 前缀 `,0,`（`%2C` 即逗号），后接完整账号 |
| `user_password` | 密码（明文） |
| `wlan_user_ip / wlan_user_mac` | 本机 / WAN 口 IP、MAC（MAC 去冒号、大写） |
| `jsVersion / v` | 前端版本号 / 防缓存随机数 |

> URL 编码：账号中的 `@` 写成 `%40`，逗号写成 `%2C`。

### 3.4 注销请求（GET）

```
http://10.255.254.1:801/eportal/?c=Portal&a=logout
    &callback=dr1004
    &login_method=1
    &user_account=drcom
    &user_password=123
    &ac_logout=1
    &wlan_user_ip=<WAN_IP>
    &wlan_user_mac=<WAN_MAC>
    &v=850
```

注销使用 Dr.COM **内置固定账号** `user_account=drcom`、`user_password=123`，并带 `ac_logout=1`，不是你的个人账号。

### 3.5 响应格式（JSONP）与成功判断

| 场景 | 返回内容 |
|---|---|
| 登录成功 | `dr1003({"result":"1","msg":"认证成功"})` |
| 已在线（正常现象） | `dr1003({"result":"0","msg":"","ret_code":2})` |
| 注销成功 | `dr1004({"result":"1","msg":"注销成功"})` |

**成功标志**：响应文本中包含 `"result":"1"`。

## 四、如何抓取你自己的认证数据

不同学校的 IP、端口、参数可能略有差异，最稳妥的方式是自己抓一次：

1. 连接校园网，浏览器按 `F12` → **Network（网络）**，勾选 `Preserve log`；
2. 在认证页手动登录；
3. 找到含 `a=login` 的请求，右键 **Copy → Copy link address**，即得到完整登录链接；
4. 点击"注销"可同理抓到 `logout` 请求；
5. 认证服务器 IP 通常就是登录页地址。

## 五、路由器方案（OpenWrt / ImmortalWrt）

思路：主脚本 `campus_auth.sh` 负责登录 / 注销 / 检测 / 通知；守护进程 `campus_monitor.sh` 每秒检测并触发重连；用 **procd** 管理（开机自启、崩溃拉起）；用 **cron** 实现每天 8:00 重登。

### 5.1 主脚本 `campus_auth.sh`

```sh
#!/bin/sh
# 校园网自动登录/注销脚本 (OpenWrt / ImmortalWrt)

# ---------------- 配置区(改成你自己的) ----------------
ACCOUNT="2025xxxxxx@telecom"     # 完整账号(含运营商后缀)
PASSWORD="xxxxxxxx"             # 密码
GATEWAY="10.255.254.1"          # 认证服务器IP
PORT="801"                      # 认证端口
PING_TARGETS="223.5.5.5 119.29.29.29"
LOG_FILE="/var/log/campus_auth.log"
WECOM_WEBHOOK=""                # 企业微信机器人地址, 留空则不通知
# ------------------------------------------------------

notify() {
    [ -z "$WECOM_WEBHOOK" ] && return 0
    local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    local data
    data=$(printf '{"msgtype":"text","text":{"content":"%s"}}' "$msg")
    curl -s -m 8 -H "Content-Type: application/json" -d "$data" "$WECOM_WEBHOOK" >/dev/null 2>&1
    log "企业微信通知已发送: $msg"
}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }
now_hp() { cut -d' ' -f1 /proc/uptime; }
http_get() { curl -s -m 10 "$1" 2>/dev/null; }

# 动态获取 WAN 口 IP 和 MAC(不写死)
get_wan_info() {
    WAN_DEV=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    WAN_IP=$(ip -4 -o addr show dev "$WAN_DEV" 2>/dev/null | awk '/inet /{print $4}' | cut -d/ -f1 | head -n1)
    WAN_MAC=$(ip link show dev "$WAN_DEV" 2>/dev/null | awk '/link\/ether/{print $2}' | tr -d ':' | tr 'a-f' 'A-F')
}

# 联网检测: HTTP探测为准(掉线时常拦HTTP而放ICMP)
is_online() {
    if command -v curl >/dev/null 2>&1; then
        local code u
        for u in http://www.baidu.com http://connect.rom.miui.com/generate_204; do
            code=$(curl -s -o /dev/null -m 4 --connect-timeout 2 --max-redirs 0 -w '%{http_code}' "$u" 2>/dev/null)
            if [ "$code" = "200" ] || [ "$code" = "204" ]; then return 0; fi
        done
        return 1
    fi
    for t in $PING_TARGETS; do ping -c 1 -W 1 "$t" >/dev/null 2>&1 && return 0; done
    return 1
}

login() {
    get_wan_info
    [ -z "$WAN_IP" ] && { log "登录失败: 无法获取WAN IP"; return 1; }
    local enc_acct
    enc_acct=$(echo "$ACCOUNT" | sed 's/@/%40/g')
    local url="http://${GATEWAY}:${PORT}/eportal/?c=Portal&a=login&callback=dr1003&login_method=1&user_account=%2C0%2C${enc_acct}&user_password=${PASSWORD}&wlan_user_ip=${WAN_IP}&wlan_user_mac=${WAN_MAC}&jsVersion=3.3.2&v=8980"
    local resp
    resp=$(http_get "$url")
    if echo "$resp" | grep -q '"result":"1"'; then
        log "登录成功 (IP=$WAN_IP MAC=$WAN_MAC)"; return 0
    fi
    log "登录失败: $resp"; return 1
}

logout() {
    get_wan_info
    [ -z "$WAN_IP" ] && { log "注销失败: 无法获取WAN IP"; return 1; }
    local url="http://${GATEWAY}:${PORT}/eportal/?c=Portal&a=logout&callback=dr1004&login_method=1&user_account=drcom&user_password=123&ac_logout=1&wlan_user_ip=${WAN_IP}&wlan_user_mac=${WAN_MAC}&v=850"
    local resp
    resp=$(http_get "$url")
    if echo "$resp" | grep -q '"result":"1"'; then log "注销成功"; return 0; fi
    log "注销失败: $resp"; return 1
}

# 断线检测并自动登录, 成功后通知含耗时
check() {
    is_online && return 0
    local t0 t1 cost i
    t0=$(now_hp)
    log "检测到断网, 尝试自动登录..."
    login
    i=0
    while [ $i -lt 15 ]; do
        sleep 1
        is_online && break
        i=$((i+1))
    done
    t1=$(now_hp)
    cost=$(awk "BEGIN{printf \"%.2f\", $t1 - $t0}")
    if is_online; then
        log "自动登录后网络已恢复, 耗时${cost}秒"
        notify "校园网掉线，已自动重连成功，断线到重连耗时 ${cost} 秒"
    else
        log "自动登录后仍无法上网, 已尝试${cost}秒"
        notify "校园网自动重连失败，已尝试 ${cost} 秒，请检查网络"
    fi
}

# 每天定时: 注销后重新登录
relogin() {
    log "执行每日重登"
    logout
    sleep 3
    login
    sleep 2
    if is_online; then
        log "每日重登完成, 网络正常"
        notify "每日重登已完成，网络正常"
    else
        notify "每日重登失败，请检查网络"
    fi
}

case "$1" in
    check)   check ;;
    login)   login ;;
    logout)  logout ;;
    relogin) relogin ;;
    status)  is_online && echo online || echo offline ;;
    *) echo "用法: $0 {check|login|logout|relogin|status}"; exit 1 ;;
esac
```

### 5.2 守护进程 `campus_monitor.sh`

```sh
#!/bin/sh
# 校园网实时监控守护进程, 每秒检测一次
INTERVAL=1
AUTH_SCRIPT="/etc/xiaoyuan/campus_auth.sh"

while true; do
    if [ "$($AUTH_SCRIPT status)" != "online" ]; then
        $AUTH_SCRIPT check
    fi
    sleep $INTERVAL
done
```

### 5.3 procd 服务 `/etc/init.d/campus_monitor`

```sh
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /etc/xiaoyuan/campus_monitor.sh
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
```

### 5.4 部署步骤

```sh
# 1. 上传脚本到 /etc/xiaoyuan/
mkdir -p /etc/xiaoyuan
chmod +x /etc/xiaoyuan/campus_auth.sh /etc/xiaoyuan/campus_monitor.sh

# 2. 安装 procd 服务并开机自启
chmod +x /etc/init.d/campus_monitor
/etc/init.d/campus_monitor enable
/etc/init.d/campus_monitor start

# 3. 语法检查(可选)
sh -n /etc/xiaoyuan/campus_auth.sh
sh -n /etc/xiaoyuan/campus_monitor.sh
```

### 5.5 定时注销重登（cron）

编辑 `/etc/crontabs/root`，加入：

```cron
# 每天8点注销重登
0 8 * * * /etc/xiaoyuan/campus_auth.sh relogin
```

保存后 `/etc/init.d/cron restart`。

## 六、电脑方案

### 6.1 仓库自带 Windows C 工具（v3.1）

仓库已提供编译好的 C 语言版（`.exe` 可直接运行，`.c` 可自行修改编译）。

**核心功能：**

- 自动校验无锡科院校园网环境（网关 Ping 检测）；
- 智能判断网络连通状态，避免重复登录；
- 账密自动保存到桌面，首次输入后免重复操作；
- 自动注销旧连接，解决多设备登录冲突；
- 临时文件自动清理，登录结果实时反馈；
- 配合"双击打开开机自启文件夹"，把脚本拖入即可开机自动运行。

**运行环境：** Windows 7/10/11（32/64 位兼容），无锡科院校园网（Wi-Fi / 有线均可）。

**编译依赖（仅自行编译时需要）：**

| 工具 | 用途 | 安装步骤 |
|---|---|---|
| MinGW | C 语言编译 | 下载 [MinGW](https://sourceforge.net/projects/mingw/)，勾选 `mingw32-gcc-g++`，将 `MinGW\bin` 加入 `Path` |
| curl | 发送 HTTP 登录请求 | 下载 [curl Windows 版](https://curl.se/windows/)，将 `curl.exe` 所在目录加入 `Path`，CMD 运行 `curl --version` 验证 |

编译示例：`gcc 无锡科院校园网连接脚本v3.1.c -o 无锡科院校园网连接脚本v3.1.exe`

### 6.2 Python 跨平台脚本（Windows / macOS / Linux）

Python 3 标准库即可，无需第三方包：

```python
#!/usr/bin/env python3
# 校园网自动登录 / 断线重连 (跨平台)
import time, uuid, json, socket
import urllib.request, urllib.parse

# ---------------- 配置区 ----------------
ACCOUNT = "2025xxxxxx@telecom"   # 完整账号
PASSWORD = "xxxxxxxx"            # 密码
GATEWAY = "10.255.254.1"         # 认证服务器IP
PORT = "801"
INTERVAL = 1                     # 检测间隔(秒)
WECOM_WEBHOOK = ""               # 企业微信机器人, 留空不通知
# ----------------------------------------


def http_get(url, timeout=8):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def get_local_info():
    """获取出口 IP 和 MAC"""
    ip = ""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((GATEWAY, 80))
        ip = s.getsockname()[0]
    finally:
        s.close()
    mac = "%012X" % uuid.getnode()
    return ip, mac


def is_online():
    """HTTP 探测: 百度 200 或 generate_204 返回 204"""
    for url, expect in [
        ("http://www.baidu.com", 200),
        ("http://connect.rom.miui.com/generate_204", 204),
    ]:
        try:
            with urllib.request.urlopen(url, timeout=4) as r:
                if r.status == expect:
                    return True
        except Exception:
            pass
    return False


def login():
    ip, mac = get_local_info()
    acct = urllib.parse.quote(ACCOUNT, safe="")
    url = (f"http://{GATEWAY}:{PORT}/eportal/?c=Portal&a=login"
           f"&callback=dr1003&login_method=1"
           f"&user_account=%2C0%2C{acct}&user_password={PASSWORD}"
           f"&wlan_user_ip={ip}&wlan_user_mac={mac}"
           f"&jsVersion=3.3.2&v=8980")
    resp = http_get(url)
    return '"result":"1"' in resp


def logout():
    ip, mac = get_local_info()
    url = (f"http://{GATEWAY}:{PORT}/eportal/?c=Portal&a=logout"
           f"&callback=dr1004&login_method=1"
           f"&user_account=drcom&user_password=123&ac_logout=1"
           f"&wlan_user_ip={ip}&wlan_user_mac={mac}&v=850")
    resp = http_get(url)
    return '"result":"1"' in resp


def notify(text):
    if not WECOM_WEBHOOK:
        return
    data = json.dumps({"msgtype": "text",
                       "text": {"content": time.strftime("%Y-%m-%d %H:%M:%S ") + text}}
    ).encode()
    req = urllib.request.Request(WECOM_WEBHOOK, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=8)
    except Exception:
        pass


def main():
    while True:
        if not is_online():
            t0 = time.time()
            login()
            for _ in range(15):
                if is_online():
                    break
                time.sleep(1)
            cost = time.time() - t0
            if is_online():
                notify(f"校园网掉线，已自动重连成功，断线到重连耗时 {cost:.2f} 秒")
            else:
                notify(f"校园网自动重连失败，已尝试 {cost:.2f} 秒，请检查网络")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
```

常驻方式：
- **Windows**：任务计划程序 → 新建任务 → 触发器"登录时" → 操作运行 `pythonw 脚本路径`；
- **macOS / Linux**：`nohup python3 campus.py &`，或写成 launchd / systemd 服务。

### 6.3 Windows PowerShell 轻量版

```powershell
# campus.ps1 —— 校园网自动重连
$Account = "2025xxxxxx@telecom"
$Password = "xxxxxxxx"
$Gateway = "10.255.254.1"
$Port = "801"

function Get-WanInfo {
    $ip = (Get-NetIPConfiguration | Where-Object {
        $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up"
    } | Select-Object -First 1).IPv4Address.IPAddress
    $mac = ((Get-NetAdapter | Where-Object Status -eq "Up" |
        Select-Object -First 1).MacAddress -replace ":", "").ToUpper()
    return @{ Ip = $ip; Mac = $mac }
}

function Test-Online {
    try {
        $r = Invoke-WebRequest -Uri "http://www.baidu.com" `
            -TimeoutSec 4 -MaximumRedirection 0 -UseBasicParsing
        return $r.StatusCode -eq 200
    } catch { return $false }
}

while ($true) {
    if (-not (Test-Online)) {
        $info = Get-WanInfo
        $acct = [uri]::EscapeDataString($Account)
        $url = "http://${Gateway}:${Port}/eportal/?c=Portal&a=login" +
            "&callback=dr1003&login_method=1" +
            "&user_account=%2C0%2C$acct&user_password=$Password" +
            "&wlan_user_ip=$($info.Ip)&wlan_user_mac=$($info.Mac)" +
            "&jsVersion=3.3.2&v=8980"
        Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing | Out-Null
    }
    Start-Sleep -Seconds 1
}
```

## 七、消息通知（可选）

以企业微信群机器人为例（钉钉、飞书同理）：

1. 企业微信群 → 群设置 → 群机器人 → 添加机器人，复制 Webhook，形如
   `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxxxxx`；
2. 填入脚本的 `WECOM_WEBHOOK` 变量；
3. 消息体为 JSON：`{"msgtype":"text","text":{"content":"通知内容"}}`。

> 掉线第一时间外网已断，通知往往发不出去，属正常；脚本会在重连成功后再发，因此成功 / 耗时消息必达。

## 八、常见问题与注意事项

1. **IP / MAC 不要写死。** WAN IP 由 DHCP 动态分配，写死会导致脚本突然失效，务必每次登录前动态获取。
2. **用 HTTP 探测而非只 ping。** 部分校园网掉线时只拦 HTTP 而放 ICMP，纯 ping 会漏判。
3. **端口与路径边界。** 学生认证只调用 `/eportal/?c=Portal&a=login|logout`，不要访问后台管理路径（如 `?c=main`）。
4. **已在线返回 `ret_code:2` 是正常的**，不代表失败；出现 `"result":"1"` 才是本次认证成功。
5. **检测频率。** 路由器 busybox 的 `sleep` 一般只支持整数秒，1 秒一次兼顾实时性与资源占用，实测断线到重连约 1~3 秒。
6. **运营商后缀**按套餐选择，不确定时先在网页端确认完整账号。
7. **合规使用。** 本项目仅用于学习交流与个人网络维护，请遵守学校网络管理规定，勿用于绕过计费或共享账号。

## License

MIT
