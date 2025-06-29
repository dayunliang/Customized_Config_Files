#!/bin/sh
# back-route-checkenv.sh
# ——————————————————————————————————
# 输出当前回程策略、路由表及iptables状态，以便对比执行前后环境
# ——————————————————————————————————

TABLE=100

echo "=== 1. 主表 default 路由 ==="
ip route show | grep '^default'

echo
echo "=== 2. 策略路由 (ip rule) ==="
ip rule show

echo
echo "=== 3. 回程表 $TABLE 内容 ==="
ip route show table $TABLE 2>/dev/null || echo "(table $TABLE empty)"

echo
echo "=== 4. mangle PREROUTING 规则 ==="
iptables -t mangle -L PREROUTING -v -n --line-numbers

echo
echo "=== 5. nat PREROUTING 规则 ==="
iptables -t nat -L PREROUTING -v -n --line-numbers
