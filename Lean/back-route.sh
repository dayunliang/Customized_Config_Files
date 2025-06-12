#!/bin/sh
# 原始回程路由脚本（未加输入接口限制）

# 可选：先删除旧规则/路由
ip rule del from 192.168.122.0/24 lookup 100 2>/dev/null
ip route flush table 100                 2>/dev/null

# 1. 针对源自 192.168.122.0/24 的流量，使用路由表 100
ip rule add from 192.168.122.0/24 lookup 100

# 2. 在表 100 中，默认出口指向主路由（192.168.12.254），
#    使用旁路由的 WAN 接口 eth1
ip route add default via 192.168.12.254 dev eth1 table 100
