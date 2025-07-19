#!/bin/sh

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 参数配置（可按需修改）
NET_CIDR="192.168.122.0/24"
TABLE_NAME="backroute"
TABLE_ID="100"
GATEWAY="192.168.12.254"
IFACE="eth1"

# 日志输出当前环境
logger -t backroute-cron "检测ip rule: $(ip rule list)"
logger -t backroute-cron "检测ip route: $(ip route show table $TABLE_ID)"

# 检查策略路由是否存在（兼容 lookup 名字或数字）
ip rule | grep -Eq "from $NET_CIDR lookup ($TABLE_ID|$TABLE_NAME)"
RULE_EXIST=$?

# 检查回程表是否存在默认路由
ip route show table $TABLE_ID | grep -q "default via $GATEWAY dev $IFACE"
ROUTE_EXIST=$?

if [ $RULE_EXIST -ne 0 ] || [ $ROUTE_EXIST -ne 0 ]; then
  logger -t backroute-cron "❗发现缺失规则，执行修复脚本..."
  /usr/bin/back-route-complete.sh
else
  logger -t backroute-cron "✅ 路由配置正常，无需修复"
fi
