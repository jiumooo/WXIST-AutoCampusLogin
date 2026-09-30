#!/bin/sh
# 校园网自动登录/断线重连脚本 (OpenWrt / ImmortalWrt)
# 用法:
#   ./campus_router.sh            守护模式(每秒检测, 掉线自动重连)
#   ./campus_router.sh once       只检测一次(可交给 cron)
#   ./campus_router.sh relogin    注销后重新登录(可交给 cron, 如每天 8 点)
#   ./campus_router.sh login|logout|status

# ---------------- 配置区(改成你自己的) ----------------
ACCOUNT="2025xxxxxx"            # 学号/工号(不含运营商后缀)
PASSWORD="xxxxxxxx"             # 密码
OPERATOR="telecom"              # 运营商: telecom(电信)/cmcc(移动)/unicom(联通); 无运营商则留空
GATEWAY="10.255.254.1"          # 认证服务器IP
PORT="801"                      # 认证端口
INTERVAL=1                      # 检测间隔(秒)
LOG_FILE="/var/log/campus_router.log"
WECOM_WEBHOOK=""                # 企业微信机器人, 留空则不通知
# ------------------------------------------------------

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

notify() {
    [ -z "$WECOM_WEBHOOK" ] && return 0
    local msg data
    msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    data=$(printf '{"msgtype":"text","text":{"content":"%s"}}' "$msg")
    curl -s -m 8 -H "Content-Type: application/json" -d "$data" "$WECOM_WEBHOOK" >/dev/null 2>&1
}

now_hp() { cut -d' ' -f1 /proc/uptime; }

# 动态获取 WAN 口 IP 和 MAC(不写死)
get_wan_info() {
    WAN_DEV=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    WAN_IP=$(ip -4 -o addr show dev "$WAN_DEV" 2>/dev/null | awk '/inet /{print $4}' | cut -d/ -f1 | head -n1)
    WAN_MAC=$(ip link show dev "$WAN_DEV" 2>/dev/null | awk '/link\/ether/{print $2}' | tr -d ':' | tr 'a-f' 'A-F')
}

# 联网检测: HTTP 探测为准(掉线时常拦 HTTP 而放 ICMP)
is_online() {
    local code u
    for u in http://www.baidu.com http://connect.rom.miui.com/generate_204; do
        code=$(curl -s -o /dev/null -m 4 --connect-timeout 2 --max-redirs 0 -w '%{http_code}' "$u" 2>/dev/null)
        if [ "$code" = "200" ] || [ "$code" = "204" ]; then return 0; fi
    done
    return 1
}

login() {
    get_wan_info
    [ -z "$WAN_IP" ] && { log "登录失败: 无法获取 WAN IP"; return 1; }
    local full_acct enc_acct url resp
    full_acct="$ACCOUNT"
    [ -n "$OPERATOR" ] && full_acct="${ACCOUNT}@${OPERATOR}"
    enc_acct=$(echo "$full_acct" | sed 's/@/%40/g')
    url="http://${GATEWAY}:${PORT}/eportal/?c=Portal&a=login&callback=dr1003&login_method=1&user_account=%2C0%2C${enc_acct}&user_password=${PASSWORD}&wlan_user_ip=${WAN_IP}&wlan_user_mac=${WAN_MAC}&jsVersion=3.3.2&v=8980"
    resp=$(curl -s -m 10 "$url" 2>/dev/null)
    if echo "$resp" | grep -q '"result":"1"'; then
        log "登录成功 (IP=$WAN_IP MAC=$WAN_MAC)"; return 0
    fi
    log "登录失败: $resp"; return 1
}

logout() {
    get_wan_info
    [ -z "$WAN_IP" ] && { log "注销失败: 无法获取 WAN IP"; return 1; }
    local url resp
    url="http://${GATEWAY}:${PORT}/eportal/?c=Portal&a=logout&callback=dr1004&login_method=1&user_account=drcom&user_password=123&ac_logout=1&wlan_user_ip=${WAN_IP}&wlan_user_mac=${WAN_MAC}&v=850"
    resp=$(curl -s -m 10 "$url" 2>/dev/null)
    if echo "$resp" | grep -q '"result":"1"'; then log "注销成功"; return 0; fi
    log "注销失败: $resp"; return 1
}

# 掉线处理: 登录并等待恢复, 通知含耗时
reconnect() {
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
        log "网络已恢复, 耗时${cost}秒"
        notify "校园网掉线，已自动重连成功，断线到重连耗时 ${cost} 秒"
    else
        log "重连失败, 已尝试${cost}秒"
        notify "校园网自动重连失败，已尝试 ${cost} 秒，请检查网络"
    fi
}

# 只检测一次
once() {
    is_online && { log "网络正常"; return 0; }
    reconnect
}

# 注销后重登
relogin() {
    log "执行定时重登"
    logout
    sleep 3
    login
    sleep 2
    if is_online; then
        log "定时重登完成, 网络正常"
        notify "定时重登已完成，网络正常"
    else
        notify "定时重登失败，请检查网络"
    fi
}

# 守护模式
daemon() {
    log "守护进程启动, 每${INTERVAL}秒检测一次"
    while true; do
        is_online || reconnect
        sleep "$INTERVAL"
    done
}

case "$1" in
    once)       once ;;
    relogin)    relogin ;;
    login)      login ;;
    logout)     logout ;;
    status)     is_online && echo online || echo offline ;;
    ""|daemon)  daemon ;;
    *) echo "用法: $0 [daemon|once|relogin|login|logout|status]"; exit 1 ;;
esac
