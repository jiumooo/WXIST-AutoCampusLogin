#!/bin/sh
# ============================================
# 校园网实时监控守护进程 (OpenWrt / ImmortalWrt)
# 每 INTERVAL 秒探测一次, 直接调认证网关login接口(一次请求=检测+自愈)
#   ret_code:2 → 在线, 无需操作
#   result:1   → 刚掉线, 本次请求已自动登录成功 → 通知含耗时
#   其他/网关不可达 → 连续 FAIL_THRESHOLD 次才走check兜底(防瞬时抖动)
# 由 /etc/init.d/campus_monitor 启动
# ============================================

# ---------------- 配置区 ----------------
INTERVAL=5                              # 探测间隔(秒)
FAIL_THRESHOLD=3                        # 连续失败次数阈值(非掉线场景, 防误报)
AUTH_SCRIPT="/etc/xiaoyuan/campus_auth.sh"
# ----------------------------------------

FAIL_COUNT=0
LAST_OK=0                               # 上次确认在线的uptime(秒), 用于计算断线到重连耗时
while true; do
    NOW=$(cut -d' ' -f1 /proc/uptime)
    $AUTH_SCRIPT probe
    RC=$?
    if [ $RC -eq 0 ]; then
        # 在线
        FAIL_COUNT=0
        LAST_OK=$NOW
    elif [ $RC -eq 1 ]; then
        # 掉线瞬间被本次探测自动登录, 已恢复
        if [ "$LAST_OK" = "0" ]; then
            COST="0.00"
        else
            COST=$(awk "BEGIN{printf \"%.2f\", $NOW - $LAST_OK}")
        fi
        logger -t campus_monitor "掉线自动重连成功, 耗时${COST}秒"
        "$AUTH_SCRIPT" notify "校园网掉线，已自动重连成功，断线到重连耗时 ${COST} 秒"
        FAIL_COUNT=0
        LAST_OK=$NOW
    elif [ $RC -eq 3 ]; then
        # 网关不可达(链路问题), 用外网兜底判断, 连续失败才处理
        if [ "$($AUTH_SCRIPT status)" != "online" ]; then
            FAIL_COUNT=$((FAIL_COUNT + 1))
            if [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ]; then
                "$AUTH_SCRIPT" check
                FAIL_COUNT=0
            fi
        else
            FAIL_COUNT=0
            LAST_OK=$NOW
        fi
    else
        # 登录失败(账号/密码/网关拒绝), 连续失败才处理
        FAIL_COUNT=$((FAIL_COUNT + 1))
        if [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ]; then
            "$AUTH_SCRIPT" check
            FAIL_COUNT=0
        fi
    fi
    sleep $INTERVAL
done
