#!/bin/sh

# ================= 配置区域 =================
TARGET_IP="192.168.12.254"
# 注意：如果你上一轮创建的服务脚本名字改成了 wstunnel，这里请相应修改
SERVICE_NAME="wstunnel-client" 
# ============================================

# 发送 3 个 Ping 包，每次超时 2 秒
if ! ping -c 3 -W 2 "$TARGET_IP" > /dev/null 2>&1; then
    # 打印到当前终端（如果是手动触发的话）
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [警告] 无法 Ping 通 $TARGET_IP，正在重启 $SERVICE_NAME..."
    
    # 写入 OpenWrt 系统日志 (通过 logread 可以看到)
    logger -t wstunnel-watchdog "Ping to $TARGET_IP failed! Restarting $SERVICE_NAME service."
    
    # 重启隧道服务
    /etc/init.d/$SERVICE_NAME restart
else
    # 链路正常，静默退出（避免刷屏系统日志）
    exit 0
fi
