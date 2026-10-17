# WXIST-AutoCampusLogin

**无锡科技职业技术学院（WXIST）校园网自动登录 / 断线自动重连**方案，基于 **Dr.COM（哆点 eportal）** 认证协议逆向分析。适用于**路由器（OpenWrt / ImmortalWrt）**与**电脑（Windows / macOS / Linux）**，支持：

- 实时检测网络连通性，断线后自动重连（**登录接口探测自愈**，掉线后 5 秒内自动恢复）；
- 可选：通过企业微信群机器人推送掉线 / 重连通知（含断线到重连耗时）。

> 账号密码、Webhook 等敏感信息请按本文说明自行配置，勿直接提交真实值到公开仓库。

---

## 🔄 本次重大更新（2026-10）：检测方式改为"登录接口探测自愈"

旧版脚本用**外网 HTTP 探测**判断是否掉线（访问百度 / generate_204，200/204 视为在线），掉线后**再**调登录接口重连——"检测"和"重连"是两步。本次更新改变检测机制，实测发现并验证了一个更优方案。

### 新旧方案对比

| 维度 | 旧方案：外网 HTTP 探测 | ✅ 新方案：登录接口探测自愈 |
|---|---|---|
| 检测原理 | 访问百度 / generate_204，看返回码 | 直接调认证网关 **login 接口** |
| 判断依据 | 外网 200 / 204 | 网关返回 `ret_code:2`（在线）/ `result:1`（掉线） |
| 检测+重连 | **两步**：先探测外网，掉线后再调 login | **一步**：探测请求本身就是登录请求，掉线瞬间自动登回 |
| 响应速度 | 掉线后要等外网连接超时（2~4 秒）才发现 | 内网网关毫秒级响应，掉线后下一个探测周期内恢复 |
| 依赖 | 依赖 DNS / 外网可达性 | **不依赖外网**，直连内网认证网关 |
| 误判风险 | 外网抖动、DNS 劫持、运营商拦截都可能误报 | 网关直判在线状态，几乎无误判 |
| 对网关影响 | 探测外网 + 登录两个请求 | 仅一个登录请求，网关幂等处理（在线时只查表，不重复认证/不计费） |
| 请求频率 | 1 秒一次 | 5 秒一次即可，负担更小 |
| 实测恢复耗时 | 掉线 1~3 秒恢复（依赖外网超时） | 掉线后 5 秒内自动恢复，实测 5.15 秒 |

### 为什么"探测登录接口"不会导致重复登录 / 被踢下线

Dr.COM 网关对**已在线账号**的登录请求是**幂等**的：返回 `ret_code:2`（账号已在线），只做状态查询，不重新认证、不踢下线、不重复计费。所以每 5 秒发一次登录请求**不是**"每 5 秒重新登录一次"，而是"每 5 秒问一次网关：我还在线吗？不在就顺手把我登上去"。

### 为什么网关不能"主动"通知掉线

实测 Dr.COM eportal 没有可用的只读状态接口（`a=index`、`a=query`、`a=getstatus` 均返回空/404），网关也不会主动推送掉线状态。所谓"断网提示"其实是**被动劫持**——访问外网时被 302 重定向到认证页，必须"有流量经过"才看得到。因此**主动探测必不可少**，而登录接口探测是所有可行探测方式里的最优解（详见 [1.1](#11-掉线检测的核心思路登录接口即探测接口)）。

---

## 目录

- [一、协议原理](#一协议原理)
- [二、关键数据](#二关键数据)
- [三、如何抓取你自己的认证数据](#三如何抓取你自己的认证数据)
- [四、路由器方案（OpenWrt / ImmortalWrt）](#四路由器方案openwrt--immortalwrt)
- [五、电脑方案](#五电脑方案)
- [六、消息通知（可选）](#六消息通知可选)
- [七、常见问题与注意事项](#七常见问题与注意事项)

---

## 一、协议原理

Dr.COM 校园网认证（eportal 页面）本质上是几个**明文 HTTP GET 接口**。浏览器在你点击"登录"时，会向认证服务器发起一个带参数的 GET 请求；服务器返回一段 **JSONP** 文本表示认证结果。

只要还原出这两个请求（**登录 login** 和**注销 logout**），任何能发 HTTP 请求的设备（路由器、电脑、单片机）都可以模拟登录，无需浏览器、无需验证码。

认证通过前，设备只能访问校园内网；认证通过后才能访问外网。

### 1.1 掉线检测的核心思路：登录接口即探测接口

实测发现 Dr.COM eportal **没有可用的"只读状态查询"接口**（`a=index`、`a=query`、`a=getstatus` 等全部返回空或 404），网关也不会主动推送掉线状态。**唯一可靠响应、且自带"在线确认"语义的接口就是登录接口**。

直接调登录接口探测，网关对已在线账号的处理是**幂等**的（不会重新认证、不会踢下线、不会重复计费），只是查表返回状态：

| 返回内容 | 含义 | 动作 |
|---|---|---|
| `dr1003({"result":"0","msg":"","ret_code":2})` | **已在线**（幂等确认） | 什么都不做 |
| `dr1003({"result":"1","msg":"认证成功"})` | **刚掉线，本次请求已自动登录成功** | 记录耗时、发通知 |
| `dr1003({"result":"0","msg":"...","ret_code":1})` | IP 与网关记录不匹配（如传了内网 IP） | 检查 wlan_user_ip |
| `dr1003({"result":"0","msg":"...","ret_code":3})` | **认证失败**（账号/密码错误、注销后冷却期等） | 检查账号配置；若刚注销，需等待 |
| 空响应 / 超时 | 网关不可达（链路问题） | 外网探测兜底 |
| 其他 | 登录失败（账号/密码/欠费等） | 连续失败 N 次才告警 |

**为什么这是最优解**：
- **检测 = 自愈**：掉线时，探测请求本身就把账号登回去了，不用"先检测、再登录"两步；
- **不依赖外网**：探测目标是认证网关（内网地址），毫秒级响应，不受 DNS / 外网抖动 / 运营商劫持影响；
- **判断准**：`ret_code:2` 是 Dr.COM 标准的"账号已在线"错误码，直接问网关"我在不在线"，而不是猜外网通不通。

### 1.2 为什么不能只靠 ping / 访问外网

- 校园网掉线时通常**只拦截 HTTP / 应用流量，ICMP（ping）依然能通**，纯 ping 检测会漏判；
- 外网 HTTP 探测（百度 / generate_204）在掉线时要等连接超时（2~4 秒）才能发现，且外网抖动会误报；
- 网关**不会主动通知你掉线**——所谓"断网提示"其实是访问外网时被 302 重定向到认证页（被动劫持），必须有流量经过才看得到。

---

## 二、关键数据

### 2.1 基本配置

| 项目 | 示例值 | 说明 |
|---|---|---|
| 认证服务器 IP | `10.255.254.1` | 学校认证网关，不同学校不同 |
| 认证端口 | `801` | eportal 服务端口（部分学校是 80） |
| 认证路径 | `/eportal/` | 学生认证入口 |
| 账号 | `你的学号` | 学号 / 工号（**不含**运营商后缀，见下行） |
| 运营商 | `telecom` | 三选一：电信 `telecom`、移动 `cmcc`、联通 `unicom`；单运营商学校可留空 |
| 密码 | `你的密码` | 校园网密码 |
| WAN IP / MAC | **动态获取** | 不要写死，见下文 |

### 2.2 登录请求（GET）

```
http://<认证服务器IP>:801/eportal/?c=Portal&a=login
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

参数说明：

| 参数 | 含义 |
|---|---|
| `c=Portal&a=login` | 控制器 `Portal`，动作 `login`（登录） |
| `callback=dr1003` | JSONP 回调函数名，任意值均可，登录常用 `dr1003` |
| `login_method=1` | 认证方式，`1` 为普通认证 |
| `user_account=%2C0%2C账号` | 前缀 `,0,`（`%2C` 即英文逗号），后接完整账号（学号@运营商） |
| `user_password` | 密码（明文） |
| `wlan_user_ip` | 本机 / WAN 口 IP（**动态获取**，必须是校园网分配地址） |
| `wlan_user_mac` | 本机 / WAN 口 MAC，去冒号、大写 |
| `jsVersion` | 前端 JS 版本号 |
| `v` | 随机数，用于防止缓存 |

> URL 编码规则：账号中的 `@` 要写成 `%40`，逗号写成 `%2C`。

> ⚠️ **`wlan_user_ip` 必须填"当前设备从校园网拿到的 IP"**。如果填了内网地址（如路由器的 192.168.1.x），网关会返回 `ret_code:1` 拒绝——这是正常的，脚本只应该在拿到校园网 IP 的设备（路由器 WAN 口 / 直连校园网的电脑）上运行。

### 2.3 注销请求（GET）

```
http://<认证服务器IP>:801/eportal/?c=Portal&a=logout
    &callback=dr1004
    &login_method=1
    &user_account=drcom
    &user_password=123
    &ac_logout=1
    &wlan_user_ip=<WAN_IP>
    &wlan_user_mac=<WAN_MAC>
    &v=850
```

注意：注销使用 Dr.COM **内置固定账号** `user_account=drcom`、`user_password=123`，并带 `ac_logout=1`，**不是**你的个人账号。

### 2.4 响应格式（JSONP）与状态判断

| 场景 | 返回内容 | 判断 |
|---|---|---|
| 在线（幂等确认） | `dr1003({"result":"0","msg":"","ret_code":2})` | `ret_code":2` = 在线 |
| 掉线后探测（自动登录） | `dr1003({"result":"1","msg":"认证成功"})` | `"result":"1"` = 本次已登录 |
| IP 不匹配（内网 IP） | `dr1003({"result":"0","msg":"","ret_code":1})` | `ret_code":1` = 认证被拒，检查 IP |
| 注销成功 | `dr1004({"result":"1","msg":"注销成功"})` | `"result":"1"` |
| 网关不可达 | 空响应 / 超时 | 链路问题，走外网兜底 |

---

## 三、如何抓取你自己的认证数据

不同学校的服务器 IP、端口、参数可能略有差异，最稳妥的方式是自己抓一次：

1. 电脑连接校园网，浏览器按 `F12` 打开开发者工具，切换到 **Network（网络）** 面板，勾选 `Preserve log`（保留日志）。
2. 在认证页面手动输入账号密码并点击登录。
3. 在 Network 中找到名为 `login`（或含 `a=login`）的请求，右键 **Copy → Copy link address**，即可得到完整登录链接和全部参数。
4. 同理，点击"注销"可抓到 `logout` 请求。
5. 认证服务器 IP 通常就是登录页面地址（如 `http://10.255.254.1:801/`）。
6. **验证你的探测是否可用**：把登录链接里的 `wlan_user_ip` 换成你设备的校园网 IP 后，直接浏览器访问——在线时返回 `ret_code:2`，这就是你的探测接口。

---

## 四、路由器方案（OpenWrt / ImmortalWrt）

思路：
- 主脚本 `campus_auth.sh` 负责探测、登录、注销、检测、通知；
- 守护进程 `campus_monitor.sh` 每 5 秒调用一次 `probe`（登录接口探测），掉线瞬间自动恢复并通知；
- 用 **procd** 管理守护进程（开机自启、崩溃自动拉起）；
- ~~用 cron 实现每天 8:00 注销重登~~ —— **已弃用**，实测会造成 20 分钟断网，详见 [4.5 踩坑记录](#45-踩坑记录不要用每天定时注销重登已弃用)。

### 4.1 主脚本 `campus_auth.sh`

完整脚本见仓库 `campus_auth.sh`（配置区在文件头部，改成你自己的即可）。核心是 `probe_auto()`：

```sh
# 探测并自动修复 (核心): 直接调认证网关login接口, 一次请求同时完成"在线检测"和"掉线重连"
# 返回码: 0=在线(ret_code:2), 1=刚掉线本次已自动登录成功(result:1), 2=登录失败, 3=网关不可达
probe_auto() {
    get_wan_info
    [ -z "$WAN_IP" ] && return 3
    local enc_acct url resp
    enc_acct=$(full_account | sed 's/@/%40/g')
    url="http://${GATEWAY}:${PORT}/eportal/?c=Portal&a=login&callback=dr1003&login_method=1&user_account=%2C0%2C${enc_acct}&user_password=${PASSWORD}&wlan_user_ip=${WAN_IP}&wlan_user_mac=${WAN_MAC}&jsVersion=3.3.2&v=8980"
    resp=$(curl -s -m 3 "$url")
    [ -z "$resp" ] && return 3
    echo "$resp" | grep -q '"ret_code":2' && return 0
    echo "$resp" | grep -q '"result":"1"' && return 1
    return 2
}
```

支持命令：`probe` / `check` / `login` / `logout` / `relogin` / `notify <msg>` / `status`。

### 4.2 守护进程 `campus_monitor.sh`

完整脚本见仓库 `campus_monitor.sh`。核心逻辑：

```sh
while true; do
    $AUTH_SCRIPT probe
    RC=$?
    if [ $RC -eq 0 ]; then
        # 在线, 无事发生
        FAIL_COUNT=0; LAST_OK=$NOW
    elif [ $RC -eq 1 ]; then
        # 掉线瞬间被本次探测自动登录, 已恢复 → 通知含耗时
        COST=$(awk "BEGIN{printf \"%.2f\", $NOW - $LAST_OK}")
        "$AUTH_SCRIPT" notify "校园网掉线，已自动重连成功，断线到重连耗时 ${COST} 秒"
        FAIL_COUNT=0; LAST_OK=$NOW
    elif [ $RC -eq 3 ]; then
        # 网关不可达(链路问题) → 外网兜底, 连续失败才处理
        ...
    else
        # 登录失败(账号/密码等) → 连续失败才处理
        ...
    fi
    sleep $INTERVAL
done
```

### 4.3 procd 服务 `/etc/init.d/campus_monitor`

完整内容见仓库 `campus_monitor.init`，核心：

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

### 4.4 部署步骤

```sh
# 1. 上传脚本
mkdir -p /etc/xiaoyuan
# 用 scp 把 campus_auth.sh、campus_monitor.sh 传到 /etc/xiaoyuan/
chmod +x /etc/xiaoyuan/campus_auth.sh /etc/xiaoyuan/campus_monitor.sh

# 2. 安装 procd 服务并设置开机自启
# 把 campus_monitor.init 传到 /etc/init.d/campus_monitor
chmod +x /etc/init.d/campus_monitor
/etc/init.d/campus_monitor enable
/etc/init.d/campus_monitor start

# 3. 语法检查(可选)
sh -n /etc/xiaoyuan/campus_auth.sh
sh -n /etc/xiaoyuan/campus_monitor.sh

# 4. 验证探测
/etc/xiaoyuan/campus_auth.sh probe && echo "在线" || echo "离线/自愈"
```

### 4.5 ⚠️ 踩坑记录：不要用"每天定时注销重登"（已弃用）

早期方案在 cron 里加了每天 8:00 注销重登，试图"防止会话老化"：

```cron
# ❌ 已弃用：实测会造成 20 分钟断网
0 8 * * * /etc/xiaoyuan/campus_auth.sh relogin
```

**实测后果（2026-10-17 真实日志）**：

```
08:00:00 执行每日重登 (8:00)
08:00:00 注销成功              ← 网断了
08:00:04 登录失败: ret_code:3   ← 重新登录被网关拒绝！
08:00:08 每日重登后网络异常
08:00:18 ~ 08:19:42  每隔30~60秒重试登录，连续19分钟全部 ret_code:3
08:19:47 掉线自动重连成功, 耗时1191秒（≈20分钟）
```

**原因**：注销后账号似乎进入了约 20 分钟的"冷却期"，期间网关持续返回 `ret_code:3`（认证失败），无论重试多少次都被拒绝。8:00 整点尤其容易触发（对比非整点时段注销后 5 秒内即可重登成功）。这等于**定时任务自己把网络搞断 20 分钟**，比不重登还糟。

**结论**：本项目已**移除**每日定时重登，只保留 `campus_monitor.sh` 每 5 秒探测自愈——登录接口探测本身是幂等的（在线返回 `ret_code:2` 不做任何操作），不会导致会话老化，也无需主动注销"刷新"。

> 如果你仍然需要定时重登，请避开整点高峰，并把时间错开到凌晨低峰（如 4:00/5:00），同时接受"注销后可能几分钟登不回"的风险。

---

## 五、电脑方案

### 5.1 Python 跨平台脚本（Windows / macOS / Linux 通用）

完整脚本见仓库 `campus_pc.py`（依赖 Python 3 标准库，无需第三方包）。逻辑与路由器版一致：每 `INTERVAL` 秒调用 `probe_auto()`，返回 1 表示掉线且本次已自动登录，发通知含耗时；网关不可达或登录失败时走外网兜底，连续失败才告警。

让脚本常驻：
- **Windows**：把脚本放进开机启动，或用"任务计划程序"新建任务 → 触发器"登录时"→ 操作运行 `pythonw 脚本路径`；
- **macOS / Linux**：`nohup python3 campus_pc.py &`，或写成 systemd / launchd 服务。

> ⚠️ 电脑直连校园网（网线插墙 / 连校园 WiFi）时用。如果电脑在路由器下面（拿内网 IP），`wlan_user_ip` 会是 192.168.x.x，网关会拒绝——此时应该用路由器方案。

### 5.2 Windows PowerShell 轻量版

```powershell
# campus.ps1 —— 校园网自动重连 (登录接口探测自愈)
$Account = "2025xxxxxx"          # 学号/工号(不含运营商后缀)
$Password = "xxxxxxxx"
$Operator = "telecom"            # 运营商: telecom/cmcc/unicom; 无运营商则留空
$Gateway = "10.255.254.1"
$Port = "801"
$Interval = 5                    # 探测间隔(秒)

function Get-WanInfo {
    $ip = (Get-NetIPConfiguration | Where-Object {
        $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up"
    } | Select-Object -First 1).IPv4Address.IPAddress
    $mac = ((Get-NetAdapter | Where-Object Status -eq "Up" |
        Select-Object -First 1).MacAddress -replace ":", "").ToUpper()
    return @{ Ip = $ip; Mac = $mac }
}

function Invoke-Probe {
    # 登录接口探测自愈: 返回 0=在线 1=掉线已自愈 2=登录失败 3=网关不可达
    $info = Get-WanInfo
    $fullAcct = $Account + $(if ($Operator) { "@" + $Operator } else { "" })
    $acct = [uri]::EscapeDataString($fullAcct)
    $url = "http://${Gateway}:${Port}/eportal/?c=Portal&a=login" +
        "&callback=dr1003&login_method=1" +
        "&user_account=%2C0%2C$acct&user_password=$Password" +
        "&wlan_user_ip=$($info.Ip)&wlan_user_mac=$($info.Mac)" +
        "&jsVersion=3.3.2&v=8980"
    try {
        $resp = (Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing).Content
        if ($resp -match '"ret_code":2') { return 0 }
        if ($resp -match '"result":"1"') { return 1 }
        return 2
    } catch { return 3 }
}

while ($true) {
    $rc = Invoke-Probe
    if ($rc -eq 1) {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 掉线自动重连成功"
    }
    Start-Sleep -Seconds $Interval
}
```

---

## 六、消息通知（可选）

以**企业微信群机器人**为例（钉钉、飞书机器人同理）：

1. 在企业微信群 → 群设置 → 群机器人 → 添加机器人，复制 Webhook 地址，形如：
   `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxxxxx`；
2. 把地址填入脚本的 `WECOM_WEBHOOK` 变量；
3. 消息体为 JSON：

```json
{"msgtype":"text","text":{"content":"通知内容"}}
```

> 注意：掉线的**第一时间外网已断**，通知往往发不出去——这是正常的。脚本会在**重连成功后**再发通知，因此成功 / 耗时消息必定送达。

---

## 七、常见问题与注意事项

1. **IP / MAC 不要写死。** 校园网 WAN IP 由 DHCP 动态分配，重启或重新认证后可能变化；写死会导致脚本突然失效。务必每次登录前动态获取。
2. **登录接口探测是幂等的。** 在线时调用登录接口返回 `ret_code:2`，网关只是查表返回状态，不会重新认证、踢你下线或重复计费。每 5 秒一次的探测对网关压力可忽略（单次内网毫秒级请求）。
3. **`ret_code:1` 是 IP 不匹配。** 如果你把 `wlan_user_ip` 填成内网地址（192.168.x.x），网关会返回 `ret_code:1` 拒绝。脚本只应在拿到校园网 IP 的设备上运行。
4. **用登录接口探测，而不是只 ping / 外网 HTTP。** 校园网掉线时可能只拦 HTTP 而放行 ICMP；外网探测要等超时且受外网抖动影响。登录接口探测最准、最快、且自带自愈。
5. **已在线返回 `ret_code:2` 是正常的**，不代表登录失败；只有出现 `"result":"1"` 才是本次认证成功。
6. **`ret_code:3` 是认证失败**（账号/密码错误，或注销后处于冷却期）。如果刚执行过注销就立刻登录，网关可能连续返回 `ret_code:3` 长达十几分钟——详见 [4.5 踩坑记录](#45-踩坑记录不要用每天定时注销重登已弃用)。
6. **检测频率。** 默认 5 秒一次（路由器 busybox 的 `sleep` 通常只支持整数秒）。想更快改 `INTERVAL=1`，但 5 秒已兼顾实时性与资源占用；实测掉线到重连约 5 秒内。
7. **运营商按套餐选择**：电信填 `telecom`、移动填 `cmcc`、联通填 `unicom`，脚本会自动拼成 `学号@运营商`；选错会登录失败。不确定时先在网页端登录一次，看浏览器地址栏里完整账号的后缀是什么。单运营商学校（无需后缀）把 `OPERATOR` 留空即可。
8. **端口与路径边界。** 学生认证只调用 `/eportal/?c=Portal&a=login|logout`；不要访问后台管理路径（如 `?c=main`），以免误操作。
9. **合规使用。** 本项目仅用于学习交流与个人网络维护，请遵守学校网络管理规定，不要用于绕过计费或共享账号。

---

## License

MIT
