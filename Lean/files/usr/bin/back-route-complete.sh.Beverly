
#!/bin/sh
# back-route-complete.sh
# 修改时间：2025-06-13
#
# 功能：
#  1. 清理 OpenClash 默认的 fwmark 回程路由（0x162）  
#  2. 清理 NAT 表中针对 DNS (UDP/TCP 53) 的 REDIRECT  
#  3. 删除旧的旁路由回程策略  
#  4. 配置新的旁路由回程：  
#     • 源自 192.168.122.0/24 → 路由表 100  
#     • 路由表 100 默认路由 via 192.168.12.254 dev eth1  
#
# 说明：  
# 重置旁路由后，执行此脚本即可同时清理 OpenClash 残留  
# 并部署回程路由，不需要再分两次运行 clear-old-openclash.sh 和 back-route.sh。

### —— 可按需调整 —— ###
LAN_NET=192.168.122.0/24   # 旁路由 LAN 侧网段
ROUTE_TABLE=100            # 回程路由表编号
GW=192.168.12.254          # 主路由（iKuai LAN）网关
WAN_IF=eth1                # 旁路由到主路由 LAN 的接口
CLASH_MARK=0x162           # OpenClash 默认打标

### 1. 清理 OpenClash 默认回程策略路由 —— ###
#ip rule del fwmark ${CLASH_MARK} ipproto icmp lookup main 2>/dev/null
#ip rule del fwmark ${CLASH_MARK}         lookup 354         2>/dev/null

### 2. 清理 DNS (53) 重定向 —— ###
iptables -t nat -D PREROUTING -p udp  --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
iptables -t nat -D PREROUTING -p tcp  --dport 53 -j REDIRECT --to-ports 53 2>/dev/null

### 3. 删除旧的回程策略 —— ###
ip rule del from ${LAN_NET} lookup ${ROUTE_TABLE}   2>/dev/null
ip route flush table ${ROUTE_TABLE}                 2>/dev/null

### 4. 添加新的回程路由 —— ###
# 4.1 源自 LAN_NET 的流量走 ROUTE_TABLE
ip rule add from ${LAN_NET} lookup ${ROUTE_TABLE}
# 4.2 在 ROUTE_TABLE 中，所有流量默认经主路由 GW、接口 WAN_IF
ip route add default via ${GW} dev ${WAN_IF} table ${ROUTE_TABLE}

### 完成提示 ###
echo "✅ 回程路由已部署："
echo "   • 源网段：${LAN_NET} → 表 ${ROUTE_TABLE}"
echo "   • 表 ${ROUTE_TABLE} 默认路由：via ${GW} dev ${WAN_IF}"
echo
echo "✅ OpenClash 默认策略与 DNS 重定向已清理"
