#!/bin/sh

# 参数配置（可按需修改）
NET_CIDR="192.168.122.0/24"
TABLE_NAME="backroute"
TABLE_ID="100"
GATEWAY="192.168.12.254"
IFACE="eth1"

# 检查策略路由是否存在
ip rule | grep -q "from $NET_CIDR lookup $TABLE_NAME"
RULE_EXIST=$?

# 检查回程表是否存在默认路由
ip route show table $TABLE_ID | grep -q "default via $GATEWAY dev $IFACE"
ROUTE_EXIST=$?

# 执行判断
if [ $RULE_EXIST -ne 0 ] || [ $ROUTE_EXIST -ne 0 ]; then
  logger -t backroute-cron "❗发现缺失规则，执行修复脚本..."
  /usr/bin/back-route-complete.sh
else
  logger -t backroute-cron "✅ 路由配置正常，无需修复"
fi
