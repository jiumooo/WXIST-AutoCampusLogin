#!/usr/bin/env python3
# ============================================
# 校园网自动登录 / 断线重连 (Windows / macOS / Linux 通用)
# 核心: 登录接口探测自愈 - 一次请求同时完成"在线检测"和"掉线重连"
# 直接运行即可, 每 INTERVAL 秒探测一次; 可选企业微信通知。
# ============================================
import time
import uuid
import json
import socket
import urllib.request

# ---------------- 配置区(改成你自己的) ----------------
ACCOUNT = "2025xxxxxx"           # 学号/工号(不含运营商后缀)
PASSWORD = "xxxxxxxx"            # 密码
OPERATOR = "telecom"             # 运营商: telecom(电信)/cmcc(移动)/unicom(联通); 无运营商则留空
GATEWAY = "10.255.254.1"         # 认证服务器IP
PORT = "801"                     # 认证端口
INTERVAL = 5                     # 探测间隔(秒)
FAIL_THRESHOLD = 3               # 非掉线场景连续失败阈值(防误报)
WECOM_WEBHOOK = ""               # 企业微信群机器人Webhook地址, 留空则不通知
# ------------------------------------------------------


def http_get(url, timeout=3):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def get_local_info():
    """获取出口 IP 和本机 MAC"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((GATEWAY, int(PORT)))
        ip = s.getsockname()[0]
    finally:
        s.close()
    mac = "%012X" % uuid.getnode()
    return ip, mac


def full_account():
    return ACCOUNT + ("@" + OPERATOR if OPERATOR else "")


def probe_auto():
    """登录接口探测自愈: 返回 0=在线, 1=掉线已自愈, 2=登录失败, 3=网关不可达"""
    ip, mac = get_local_info()
    if not ip:
        return 3
    import urllib.parse
    acct = urllib.parse.quote(full_account(), safe="")
    url = (
        f"http://{GATEWAY}:{PORT}/eportal/?c=Portal&a=login"
        f"&callback=dr1003&login_method=1"
        f"&user_account=%2C0%2C{acct}&user_password={PASSWORD}"
        f"&wlan_user_ip={ip}&wlan_user_mac={mac}"
        f"&jsVersion=3.3.2&v=8980"
    )
    try:
        resp = http_get(url)
    except Exception:
        return 3
    if '"ret_code":2' in resp:
        return 0
    if '"result":"1"' in resp:
        return 1
    return 2


def is_online():
    """外网探测(兜底): 百度 200 或 generate_204 返回 204"""
    for url, expect in (
        ("http://www.baidu.com", 200),
        ("http://connect.rom.miui.com/generate_204", 204),
    ):
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status == expect:
                    return True
        except Exception:
            pass
    return False


def login():
    """直接登录(兜底用)"""
    ip, mac = get_local_info()
    import urllib.parse
    acct = urllib.parse.quote(full_account(), safe="")
    url = (
        f"http://{GATEWAY}:{PORT}/eportal/?c=Portal&a=login"
        f"&callback=dr1003&login_method=1"
        f"&user_account=%2C0%2C{acct}&user_password={PASSWORD}"
        f"&wlan_user_ip={ip}&wlan_user_mac={mac}"
        f"&jsVersion=3.3.2&v=8980"
    )
    resp = http_get(url, timeout=3)
    return '"result":"1"' in resp or '"ret_code":2' in resp


def notify(text):
    if not WECOM_WEBHOOK:
        return
    data = json.dumps(
        {"msgtype": "text",
         "text": {"content": time.strftime("%Y-%m-%d %H:%M:%S ") + text}}
    ).encode()
    req = urllib.request.Request(
        WECOM_WEBHOOK, data=data,
        headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=8)
    except Exception:
        pass


def main():
    fail_count = 0
    last_ok = 0.0
    while True:
        now = time.time()
        rc = probe_auto()
        if rc == 0:
            # 在线
            fail_count = 0
            last_ok = now
        elif rc == 1:
            # 掉线瞬间被本次探测自动登录, 已恢复
            cost = (now - last_ok) if last_ok else 0.0
            notify(f"校园网掉线，已自动重连成功，断线到重连耗时 {cost:.2f} 秒")
            fail_count = 0
            last_ok = now
        elif rc == 3:
            # 网关不可达(链路问题), 用外网兜底判断, 连续失败才处理
            if not is_online():
                fail_count += 1
                if fail_count >= FAIL_THRESHOLD:
                    t0 = time.time()
                    login()
                    if is_online():
                        notify(f"校园网掉线，已自动重连成功，断线到重连耗时 {time.time()-t0:.2f} 秒")
                    else:
                        notify("校园网自动重连失败，请检查网络")
                    fail_count = 0
            else:
                fail_count = 0
                last_ok = now
        else:
            # 登录失败(账号/密码/网关拒绝), 连续失败才处理
            fail_count += 1
            if fail_count >= FAIL_THRESHOLD:
                t0 = time.time()
                login()
                if is_online():
                    notify(f"校园网掉线，已自动重连成功，断线到重连耗时 {time.time()-t0:.2f} 秒")
                else:
                    notify("校园网自动重连失败，请检查网络")
                fail_count = 0
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
