#!/bin/sh
# ============================================
# 校园网自动登录/注销脚本 (OpenWrt / ImmortalWrt)
# 核心: 登录接口探测自愈 - 一次请求同时完成"在线检测"和"掉线重连"
# 用法:
#   campus_auth.sh probe     探测一次(在线=0/掉线自愈=1/登录失败=2/网关不可达=3)
#   campus_auth.sh check     断网检测并自动登录(含重连耗时通知)
#   campus_auth.sh login     登录
#   campus_auth.sh logout    注销
#   campus_auth.sh relogin   注销后重新登录(可交给 cron)
#   campus_auth.sh notify <msg>  发送企业微信通知
#   campus_auth.sh status    输出 online / offline
# ============================================

# ---------------- 配置区(改成你自己的) ----------------
ACCOUNT="2025xxxxxx"            # 学号/工号(不含运营商后缀)
PASSWORD="xxxxxxxx"             # 密码
OPERATOR="telecom"              # 运营商: telecom(电信)/cmcc(移动)/unicom(联通); 无运营商则留空
GATEWAY="10.255.254.1"          # 认证服务器IP
PORT="801"                      # 认证端口
PING_TARGETS="223.5.5.5 119.29.29.29"   # 兜底ping目标
LOG_FILE="/var/log/campus_auth.log"
WECOM_WEBHOOK=""                # 企业微信群机器人Webhook地址, 留空则不通知
LOGIN_MAX_RETRY=2              # 登录失败最大重试次数
LOGIN_RETRY_INTERVAL=1         # 登录重试间隔(秒)
# ------------------------------------------------------

# 发送企业微信通知 (群机器人Webhook), 检查发送结果
notify() {
    [ -z "$WECOM_WEBHOOK" ] && return 0
    local msg="$1"
    msg="$(date '+%Y-%m-%d %H:%M:%S') $msg"
    local data rc
    data=$(printf '{"msgtype":"text","text":{"content":"%s"}}' "$msg")
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 8 -H "Content-Type: application/json" -d "$data" "$WECOM_WEBHOOK" >/dev/null 2>&1
        rc=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T 8 --header="Content-Type: application/json" --post-data="$data" "$WECOM_WEBHOOK" >/dev/null 2>&1
        rc=$?
    else
        uclient-fetch -qO- -T 8 --post-data="$data" "$WECOM_WEBHOOK" >/dev/null 2>&1
        rc=$?
    fi
    if [ $rc -eq 0 ]; then
        log "企业微信通知已发送: $msg"
    else
        log "企业微信通知发送失败(rc=$rc): $msg"
    fi
}

# 写日志
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# 获取高精度时间戳(秒, 内核厘秒精度), 取自/proc/uptime
now_hp() {
    cut -d' ' -f1 /proc/uptime
}

# HTTP GET 通用函数 (优先 curl, 其次 wget, 最后 uclient-fetch)
http_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 3 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T 3 "$url" 2>/dev/null
    else
        uclient-fetch -qO- --timeout=3 "$url" 2>/dev/null
    fi
}

# 动态获取 WAN 口 IP 和 MAC (不写死, 防地址变化)
get_wan_info() {
    WAN_DEV=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [ -z "$WAN_DEV" ] && WAN_DEV=$(uci get network.wan.device 2>/dev/null)
    WAN_IP=$(ip -4 -o addr show dev "$WAN_DEV" 2>/dev/null | awk '/inet /{print $4}' | cut -d/ -f1 | head -n1)
    WAN_MAC=$(ip link show dev "$WAN_DEV" 2>/dev/null | awk '/link\/ether/{print $2}' | tr -d ':' | tr 'a-f' 'A-F')
}

# 完整账号 = 学号 + 运营商后缀
full_account() {
    [ -n "$OPERATOR" ] && echo "${ACCOUNT}@${OPERATOR}" || echo "$ACCOUNT"
}

# 联网检测(兜底用): 以HTTP探测为准(真实上网能力)
# 校园网掉线时HTTP被拦截但ICMP可能仍通, 故不能只靠ping
# 200(百度)或204(generate_204)即在线, 双端点冗余防单点误判
is_online() {
    if command -v curl >/dev/null 2>&1; then
        local code u
        for u in http://www.baidu.com http://connect.rom.miui.com/generate_204; do
            code=$(curl -s -o /dev/null -m 2 --connect-timeout 1 --max-redirs 0 -w '%{http_code}' "$u" 2>/dev/null)
            if [ "$code" = "200" ] || [ "$code" = "204" ]; then
                return 0
            fi
        done
        return 1
    fi
    # 无curl时才用ping兜底
    for t in $PING_TARGETS; do
        ping -c 1 -W 1 "$t" >/dev/null 2>&1 && return 0
    done
    return 1
}

# 探测并自动修复 (核心): 直接调认证网关login接口, 一次请求同时完成"在线检测"和"掉线重连"
# 返回码: 0=在线(ret_code:2), 1=刚掉线本次已自动登录成功(result:1), 2=登录失败(账号/密码等), 3=网关不可达
probe_auto() {
    get_wan_info
    if [ -z "$WAN_IP" ]; then
        return 3
    fi
    local enc_acct url resp
    enc_acct=$(full_account | sed 's/@/%40/g')
    url="http://${GATEWAY}:${PORT}/eportal/?c=Portal&a=login&callback=dr1003&login_method=1&user_account=%2C0%2C${enc_acct}&user_password=${PASSWORD}&wlan_user_ip=${WAN_IP}&wlan_user_mac=${WAN_MAC}&jsVersion=3.3.2&v=8980"
    resp=$(curl -s -m 3 "$url")
    [ -z "$resp" ] && return 3
    echo "$resp" | grep -q '"ret_code":2' && return 0
    echo "$resp" | grep -q '"result":"1"' && return 1
    return 2
}

# 登录 (失败自动重试, 最多 LOGIN_MAX_RETRY 次)
# 成功标志: result:1(登录成功) 或 ret_code:2(已在线/账号已登录)
login() {
    get_wan_info
    if [ -z "$WAN_IP" ]; then
        log "登录失败: 无法获取WAN IP"
        return 1
    fi
    local enc_acct
    enc_acct=$(full_account | sed 's/@/%40/g')
    local url="http://${GATEWAY}:${PORT}/eportal/?c=Portal&a=login&callback=dr1003&login_method=1&user_account=%2C0%2C${enc_acct}&user_password=${PASSWORD}&wlan_user_ip=${WAN_IP}&wlan_user_mac=${WAN_MAC}&jsVersion=3.3.2&v=8980"
    local resp attempt
    for attempt in $(seq 1 $LOGIN_MAX_RETRY); do
        resp=$(http_get "$url")
        if echo "$resp" | grep -q '"result":"1"'; then
            log "登录成功 (IP=$WAN_IP MAC=$WAN_MAC) 第${attempt}次尝试"
            return 0
        fi
        if echo "$resp" | grep -q '"ret_code":2'; then
            log "账号已在线(ret_code:2), 视为登录成功 (IP=$WAN_IP) 第${attempt}次尝试"
            return 0
        fi
        if [ $attempt -lt $LOGIN_MAX_RETRY ]; then
            sleep $LOGIN_RETRY_INTERVAL
        fi
    done
    log "登录失败(已重试${LOGIN_MAX_RETRY}次): $resp"
    return 1
}

# 注销
logout() {
    get_wan_info
    if [ -z "$WAN_IP" ]; then
        log "注销失败: 无法获取WAN IP"
        return 1
    fi
    local url="http://${GATEWAY}:${PORT}/eportal/?c=Portal&a=logout&callback=dr1004&login_method=1&user_account=drcom&user_password=123&ac_logout=1&wlan_user_ip=${WAN_IP}&wlan_user_mac=${WAN_MAC}&v=850"
    local resp
    resp=$(http_get "$url")
    if echo "$resp" | grep -q '"result":"1"'; then
        log "注销成功"
        return 0
    fi
    log "注销失败: $resp"
    return 1
}

# 断网检测并自动登录 (由守护进程在网关不可达/登录失败时兜底调用), 重连成功后通知含断线到重连耗时
check() {
    if is_online; then
        return 0
    fi
    local t0 t1 cost i
    t0=$(now_hp)
    log "检测到断网, 尝试自动登录..."
    login
    # 轮询等待网络恢复, 最多等10秒(配合is_online 2秒超时, 最坏约20秒)
    i=0
    while [ $i -lt 10 ]; do
        sleep 1
        if is_online; then
            break
        fi
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
        log "每日重登后网络异常"
        notify "每日重登失败，请检查网络"
    fi
}

# 主入口
case "$1" in
    check)   check ;;
    probe)   probe_auto ;;
    login)   login ;;
    logout)  logout ;;
    relogin) relogin ;;
    notify)  shift; notify "$*" ;;
    status)  if is_online; then echo online; else echo offline; fi ;;
    *)
        echo "用法: $0 {check|probe|login|logout|relogin|notify <msg>|status}"
        exit 1
        ;;
esac
