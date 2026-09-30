#!/usr/bin/env python3
# 校园网自动登录 / 断线重连 (Windows / macOS / Linux)
# 直接运行即可, 每秒检测一次, 掉线自动重连; 可选企业微信通知。
import time
import uuid
import json
import socket
import urllib.request
import urllib.parse

# ---------------- 配置区(改成你自己的) ----------------
ACCOUNT = "2025xxxxxx@telecom"   # 完整账号(含运营商后缀)
PASSWORD = "xxxxxxxx"            # 密码
GATEWAY = "10.255.254.1"         # 认证服务器IP
PORT = "801"                     # 认证端口
INTERVAL = 1                     # 检测间隔(秒)
WECOM_WEBHOOK = ""               # 企业微信机器人, 留空则不通知
# ------------------------------------------------------


def http_get(url, timeout=8):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")


def get_local_info():
    """获取出口 IP 和本机 MAC"""
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
    for url, expect in (
        ("http://www.baidu.com", 200),
        ("http://connect.rom.miui.com/generate_204", 204),
    ):
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
    url = (
        f"http://{GATEWAY}:{PORT}/eportal/?c=Portal&a=login"
        f"&callback=dr1003&login_method=1"
        f"&user_account=%2C0%2C{acct}&user_password={PASSWORD}"
        f"&wlan_user_ip={ip}&wlan_user_mac={mac}"
        f"&jsVersion=3.3.2&v=8980"
    )
    resp = http_get(url)
    return '"result":"1"' in resp


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
