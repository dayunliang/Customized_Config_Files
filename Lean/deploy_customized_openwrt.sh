#!/bin/sh
#
# zzz-default-settings
# 放置于：package/lean/default-settings/files/zzz-default-settings
# 触发机制：系统首次启动时会被 /etc/init.d/boot 执行，执行完毕后在脚本末尾会删除自身，确保只运行一次。
#

# =============================================================================
# 1. 设置 LuCI 界面语言与默认主题
# =============================================================================

# 调用 UCI (Unified Configuration Interface) 设置系统默认语言为简体中文
uci set luci.main.lang='zh_cn'

# 设置 LuCI 默认主题指向 bootstrap 目录。
# 备注：虽然路径写的是 bootstrap，但在 Lean 源码的编译逻辑中，如果你放入了 neobird 主题，
# 且将其设为了默认，这里实际上会调用你指定的 neobird 主题资源。
uci set luci.main.mediaurlbase='/luci-static/bootstrap'

# 提交（保存）luci 相关的配置更改到 /etc/config/luci 文件中
uci commit luci

# =============================================================================
# 2. 设置系统时区、主机名和 NTP 服务器
# =============================================================================
# 使用 uci -q batch 批量静默执行多条命令，提高执行效率
uci -q batch <<-EOF
  # 设置系统时区格式为 CST-8（东八区）
  set system.@system[0].timezone='CST-8'
  # 设置时区具体名称为亚洲/上海
  set system.@system[0].zonename='Asia/Shanghai'
  # 设定路由器主机名，方便在内网中识别
  set system.@system[0].hostname='DOIT.2nd.Router'
  # 清空 OpenWrt 默认自带的（通常是国外的）NTP 时间服务器
  delete system.ntp.server
  # 依次添加国内常用且稳定的 NTP 时间服务器，确保时间同步速度
  add_list system.ntp.server='ntp1.aliyun.com'
  add_list system.ntp.server='ntp.tencent.com'
  add_list system.ntp.server='ntp.ntsc.ac.cn'
  add_list system.ntp.server='time.ustc.edu.cn'
EOF
# 保存 system 相关的更改到 /etc/config/system
uci commit system

# =============================================================================
# 3. 启用匿名挂载
# =============================================================================
# 允许未定义的磁盘设备插入时自动匿名挂载（常用于随身 U 盘临时接入）
uci set fstab.@global[0].anon_mount=1
uci commit fstab

# =============================================================================
# 4. 清理 LuCI 状态页面
# =============================================================================
# 强制删除多路均衡(mwan)、UPnP、动态域名(ddns)和 DLNA 的状态显示页面。
# 目的：精简 LuCI 首页的状态概览，隐藏不需要的模块信息。
rm -f /usr/lib/lua/luci/view/admin_status/index/{mwan,upnp,ddns,minidlna}.htm

# =============================================================================
# 5. 重命名 “Services” 菜单为 “NAS”
# =============================================================================
# 遍历指定的后台 Lua 控制器文件（如 Samba, aria2 等）
for ctl in aria2 hd_idle samba samba4 minidlna transmission mjpg-streamer p910nd usb_printer xunlei; do
  # 检查文件是否存在，如果存在，使用 sed 将菜单路径中的 "services" 替换为 "nas"
  [ -f "/usr/lib/lua/luci/controller/${ctl}.lua" ] && sed -i 's/"services"/"nas"/g' /usr/lib/lua/luci/controller/${ctl}.lua
done

# 遍历前端显示的 HTML 视图文件
for view in overview_status minidlna_status; do
  # 同样地，将视图文件内的 services 标识替换为 nas，完成菜单整体重定向
  [ -f "/usr/lib/lua/luci/view/${view}.htm" ] && sed -i 's/services/nas/g' /usr/lib/lua/luci/view/${view}.htm
done

# =============================================================================
# 6. 更换 OPKG 源为阿里云，注释第三方源
# =============================================================================
# 将默认官方源替换为阿里云镜像，加速国内安装插件的速度
sed -i 's|https://downloads.openwrt.org|https://mirrors.aliyun.com/openwrt|g' /etc/opkg/distfeeds.conf
# 注释掉不需要的第三方个人源，防止依赖冲突或网络连通性问题
sed -i '/smpackage/s/^/#/'         /etc/opkg/distfeeds.conf
sed -i '/kenzo/s/^/#/'             /etc/opkg/distfeeds.conf
sed -i '/small/s/^/#/'             /etc/opkg/distfeeds.conf
sed -i '/openwrt_istore/s|^|#|'    /etc/opkg/distfeeds.conf
# 取消 OPKG 的签名检查，方便安装非官方签名的自定义 ipk 插件
sed -i '/check_signature/s/^/#/'   /etc/opkg.conf

# =============================================================================
# 7. 重置 root 密码
# =============================================================================
# 修改 /etc/shadow 文件，将 root 密码的哈希值替换。
# 这里的哈希值对应明文密码 "password"。如果需要其他密码，请用 openssl passwd -1 重新生成。
sed -i 's#root::0:0:99999:7:::#root:$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.:0:0:99999:7:::#g' /etc/shadow

# =============================================================================
# 8. 优化 Dnsmasq 日志与 LuCI 缓存
# =============================================================================
# 删除默认的日志设施配置
sed -i '/log-facility/d' /etc/dnsmasq.conf
# 将 Dnsmasq 的日志输出重定向到空设备（/dev/null），停止记录 DNS 查询日志，减少闪存磨损
echo "log-facility=/dev/null" >> /etc/dnsmasq.conf
# 清理 LuCI 的模块和索引缓存，确保刚修改的菜单名称（如 NAS）立刻生效
rm -rf /tmp/luci-modulecache/ /tmp/luci-indexcache

# =============================================================================
# 9. 默认开启所有无线接口
# =============================================================================
# 从无线配置文件中删除 disabled 选项，确保 WiFi 默认开启
sed -i '/option disabled/d' /etc/config/wireless
# 从 mac80211 初始化脚本中移除默认禁用 WiFi 的指令
sed -i '/set wireless.radio${devidx}.disabled/d' /lib/wifi/mac80211.sh

# =============================================================================
# 10. 自定义固件版本信息
# =============================================================================
# 删除原有的版本号，写入自定义修订版本号 '140.T1.6A'
sed -i '/DISTRIB_REVISION/d'    /etc/openwrt_release
echo "DISTRIB_REVISION='140.T1.6A'" >> /etc/openwrt_release
# 删除原有的系统描述，修改为 'OpenWrt '
sed -i '/DISTRIB_DESCRIPTION/d' /etc/openwrt_release
echo "DISTRIB_DESCRIPTION='OpenWrt '" >> /etc/openwrt_release

# =============================================================================
# 11. 网络与 DHCP 静态设置（针对 IPv4） + 保持 DSA 桥接 + 彻底关闭 IPv6
# =============================================================================

# 清理旧版本遗留的网络接口定义字段，防止与新版 DSA 架构冲突（2>/dev/null 屏蔽错误提示）
uci delete network.lan.ifname 2>/dev/null || true
uci delete network.lan.type   2>/dev/null || true
uci delete network.wan.ifname 2>/dev/null || true

# ===== LAN：静态 IPv4 =====
# 将 LAN 口绑定到物理网卡 eth0
uci set network.lan.device='eth0'
# 设定为静态 IP 模式
uci set network.lan.proto='static'
uci set network.lan.ipaddr='10.140.166.144'
uci set network.lan.netmask='255.255.255.0'

# 禁用 LAN 的 IPv6 前缀分配（长度设为 0）
uci set network.lan.ip6assign='0'

# DHCP：由于上游 iKuai 提供 DHCP，这里必须把 OpenWrt 自身的 LAN DHCP 关掉
uci set dhcp.lan=dhcp
uci set dhcp.lan.interface='lan'
# ignore='1' 彻底禁用此接口的 DHCP 服务
uci set dhcp.lan.ignore='1'
# 彻底禁用 DHCPv6 和路由通告 (RA)
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.ra_management='0'

# 安全增强 1: 遍历防火墙区域，找到名字为 lan 的区域，将其入站(input)规则改为 REJECT
# 作用：禁止 LAN 侧设备主动访问本路由器的系统服务，提升安全性。
for s in $(uci -q show firewall | grep "=zone" | cut -d= -f1); do
  [ "$(uci -q get ${s}.name 2>/dev/null)" = "lan" ] && uci set ${s}.input='REJECT' && break
done

uci commit firewall

# ===== WAN：eth1 + 静态 IPv4 =====
# 将 WAN 口绑定到物理网卡 eth1，并配置静态 IP 和上游网关、DNS
uci set network.wan.device='eth1'
uci set network.wan.proto='static'
uci set network.wan.ipaddr='10.140.6.144'
uci set network.wan.netmask='255.255.255.0'
uci set network.wan.gateway='10.140.6.1'
uci set network.wan.dns='10.140.6.10'
uci set network.wan.broadcast='10.140.6.255'

uci commit network
uci commit dhcp

# 彻底清理出厂默认可能带有的 IPv6 WAN 接口 (wan6) 和相关 DHCP 设置
uci delete network.wan6  2>/dev/null
uci delete dhcp.wan6     2>/dev/null
uci commit network
uci commit dhcp

# 再次清理 ip6assign 字段，确保 LuCI 界面明确显示 IPv6 “已禁用”
uci delete network.lan.ip6assign 2>/dev/null
uci delete network.wan.ip6assign 2>/dev/null
uci commit network

# —— 内核层面彻底禁用 IPv6 —— 
# 向 sysctl.conf 追加内核参数，禁用所有网卡、默认配置和本地回环的 IPv6 协议栈
grep -q 'disable_ipv6' /etc/sysctl.conf || cat << 'EOF' >> /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

# 使刚才修改的内核参数立即生效
sysctl -p >/dev/null 2>&1

# 禁用并停止 odhcpd（负责处理 IPv6 DHCP/RA 的守护进程），彻底断绝 IPv6 干扰
/etc/init.d/odhcpd disable
/etc/init.d/odhcpd stop

# 补充设置新版和旧版的兼容字段，增强配置稳定性
uci set network.lan.ifname='eth0'
uci set network.wan.ifname='eth1'
uci commit network

# =============================================================================
# 12. 防火墙 wg0 相关设置（核心安全规则区）
# =============================================================================

# 检测并绑定网络设备名称，确保 LAN 和 WAN 接口均拥有明确的硬件指向 (device 或 ifname)
LAN_DEV="$(uci -q get network.lan.device 2>/dev/null || echo '')"
LAN_IFNAME="$(uci -q get network.lan.ifname 2>/dev/null || echo '')"
if [ -z "$LAN_DEV" ] && [ -z "$LAN_IFNAME" ]; then
  uci set network.lan.device='eth0'
fi

WAN_DEV="$(uci -q get network.wan.device 2>/dev/null || echo '')"
WAN_IFNAME="$(uci -q get network.wan.ifname 2>/dev/null || echo '')"
if [ -z "$WAN_DEV" ] && [ -z "$WAN_IFNAME" ]; then
  uci set network.wan.device='eth1'
fi
uci commit network

# 12.1 确保 wan zone 包含了 network 'wan' 的绑定映射
WANZONE=""
for sec in $(uci -q show firewall | grep "=zone" | cut -d= -f1); do
  name="$(uci -q get ${sec}.name 2>/dev/null)"
  [ "$name" = "wan" ] && WANZONE="$sec" && break
done

if [ -n "$WANZONE" ]; then
  # 检查 wan 区域是否包含了 wan 接口，如果没有则加上
  CUR_NETS="$(uci -q get ${WANZONE}.network 2>/dev/null || echo "")"
  echo "$CUR_NETS" | grep -qw 'wan' || uci add_list ${WANZONE}.network='wan'
fi

# 12.2 查找或创建 wg0 防火墙区域（WireGuard 所属区域）
WGZONE=""
for sec in $(uci -q show firewall | grep "=zone" | cut -d= -f1); do
  name="$(uci -q get ${sec}.name 2>/dev/null)"
  [ "$name" = "wg0" ] && WGZONE="$sec" && break
done

if [ -z "$WGZONE" ]; then
  # 如果不存在，则新建 wg0 区域，并设定入站、出站、转发全部默认 ACCEPT
  uci add firewall zone >/dev/null
  uci set firewall.@zone[-1].name='wg0'
  uci set firewall.@zone[-1].input='ACCEPT'
  uci set firewall.@zone[-1].output='ACCEPT'
  uci set firewall.@zone[-1].forward='ACCEPT'
  uci add_list firewall.@zone[-1].network='wg0'
fi

# 12.3 设置区域转发
HAS_WG0_LAN=0
HAS_WG0_WAN=0
HAS_WAN_WG0=0

for sec in $(uci -q show firewall | grep "=forwarding" | cut -d= -f1); do
  src="\((uci -q get\){sec}.src 2>/dev/null)"
  dest="\((uci -q get\){sec}.dest 2>/dev/null)"
  [ "\(src" = "wg0" -a "\)dest" = "lan" ] && HAS_WG0_LAN=1
  [ "\(src" = "wg0" -a "\)dest" = "wan" ] && HAS_WG0_WAN=1
  [ "\(src" = "wan" -a "\)dest" = "wg0" ] && HAS_WAN_WG0=1
done

# 允许 wg0 访问 lan：Beverly 可以访问 DOIT LAN（10.140.166.0/24）
[ "$HAS_WG0_LAN" -eq 0 ] && {
  uci add firewall forwarding >/dev/null
  uci set firewall.@forwarding[-1].src='wg0'
  uci set firewall.@forwarding[-1].dest='lan'
}

# 允许 wg0 访问 wan：Beverly 可以访问 DOIT 网关/服务（10.140.6.0/24）
[ "$HAS_WG0_WAN" -eq 0 ] && {
  uci add firewall forwarding >/dev/null
  uci set firewall.@forwarding[-1].src='wg0'
  uci set firewall.@forwarding[-1].dest='wan'
}

# 允许 wan 访问 wg0：允许来自 iKuai 等上级跨网段转发进来的流量进入 WireGuard 隧道
[ "$HAS_WAN_WG0" -eq 0 ] && {
  uci add firewall forwarding >/dev/null
  uci set firewall.@forwarding[-1].src='wan'
  uci set firewall.@forwarding[-1].dest='wg0'
}

# 12.4 DNS 重定向：防止内网设备自行指定 DNS 绕过路由，强制将 53 端口流量劫持到本机
HAS_DNS_REDIRECT=0
for sec in $(uci -q show firewall | grep "=redirect" | cut -d= -f1); do
  name="$(uci -q get ${sec}.name 2>/dev/null)"
  [ "$name" = "dns_redirect" ] && HAS_DNS_REDIRECT=1 && break
done

[ "$HAS_DNS_REDIRECT" -eq 0 ] && {
  uci add firewall redirect >/dev/null
  uci set firewall.@redirect[-1].name='dns_redirect'
  uci set firewall.@redirect[-1].src='lan'
  uci set firewall.@redirect[-1].src_dport='53'
  uci set firewall.@redirect[-1].family='ipv4'
  uci set firewall.@redirect[-1].proto='tcpudp'
  uci set firewall.@redirect[-1].target='DNAT'
  uci set firewall.@redirect[-1].dest_port='53'
}

# 12.5 安全增强 2: 业务与管理白名单
# 允许回环地址通信，保证内部插件（如代理核心）正常运行
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-Local-Loopback'
uci set firewall.@rule[-1].src='*'
uci set firewall.@rule[-1].dest_ip='127.0.0.1'
uci set firewall.@rule[-1].target='ACCEPT'

# 允许 iKuai 网关主动发起通信，防止被 LAN 的 REJECT 策略误拦截
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name='Allow-iKuai-Input-All'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].src_ip='10.140.166.254'
uci set firewall.@rule[-1].proto='all'
uci set firewall.@rule[-1].target='ACCEPT'

# 12.6 WAN 管理白名单：允许特定网段和 IP 访问路由器本机（用于管理，如 SSH/网页端）
HAS_WAN_ADMIN=0
for sec in $(uci -q show firewall | grep "=rule" | cut -d= -f1); do
  name="$(uci -q get ${sec}.name 2>/dev/null)"
  [ "$name" = "Allow-WAN-LAN-Admin" ] && HAS_WAN_ADMIN=1 && break
done

[ "$HAS_WAN_ADMIN" -eq 0 ] && {
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='Allow-WAN-LAN-Admin'
  uci set firewall.@rule[-1].src='wan'
  # 包含管理网络、笔记本 IP 及特定的几个准入 IP
  uci set firewall.@rule[-1].src_ip='10.140.6.0/24 10.140.90.2 10.10.30.2 10.10.30.3 10.10.30.4 10.10.30.5 10.140.80.56'
  uci set firewall.@rule[-1].proto='all'
  uci set firewall.@rule[-1].target='ACCEPT'
  uci set firewall.@rule[-1].family='ipv4'
}

# =============================================================================
# 12.7 WAN→WG0 精确放行：控制 DOIT 侧白名单可以访问 Beverly
# =============================================================================
HAS_VPN_WG_RULE=0
for sec in $(uci -q show firewall | grep "=rule" | cut -d= -f1); do
  name="$(uci -q get ${sec}.name 2>/dev/null)"
  # 校验已统一修正为 Allow-Specific-to-wg0
  [ "$name" = "Allow-Specific-to-wg0" ] && HAS_VPN_WG_RULE=1 && break
done

[ "$HAS_VPN_WG_RULE" -eq 0 ] && {
  # 1. 添加白名单放行规则
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='Allow-Specific-to-wg0'
  uci set firewall.@rule[-1].src='*'
  uci set firewall.@rule[-1].src_ip='10.140.90.2 10.140.6.200 10.140.80.56'
  uci set firewall.@rule[-1].dest='wg0'
  uci set firewall.@rule[-1].proto='all'
  uci set firewall.@rule[-1].target='ACCEPT'
  uci set firewall.@rule[-1].family='ipv4'

  # 2. 紧接着添加非白名单的兜底拒绝规则 (严格遵循自上而下匹配逻辑)
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='Deny-Others-to-wg0'
  uci set firewall.@rule[-1].src='*'
  uci set firewall.@rule[-1].dest='wg0'
  uci set firewall.@rule[-1].proto='all'
  uci set firewall.@rule[-1].target='REJECT'
}

# 提交所有防火墙修改
uci commit firewall

# =============================================================================
# 13. 取消 Dropbear 接口绑定
# =============================================================================
# 删除 SSH (Dropbear) 的接口绑定，使其监听 0.0.0.0，实际能否连通交由第12段的防火墙管控
uci delete dropbear.@dropbear[0].Interface 2>/dev/null
uci commit dropbear

# =============================================================================
# 14. 固定 WireGuard 配置
# =============================================================================
uci -q batch << 'EOF'
  # 定义 wg0 接口协议和私钥（__WG_PRIVKEY__ 为占位符或编译时替换的值）
  set network.wg0='interface'
  set network.wg0.proto='wireguard'
  set network.wg0.private_key='__WG_PRIVKEY__'
  # 本地监听端口设为 8443
  set network.wg0.listen_port='8443'
  # 设定本机在隧道内的 IP 地址
  add_list network.wg0.addresses='10.0.0.3/24'

  # 清理可能存在的出厂 peer 节点
  delete network.@wireguard_wg0[0]

  # 注册对端节点（Beverly）
  add network wireguard_wg0
  set network.@wireguard_wg0[-1].description='Beverly'
  set network.@wireguard_wg0[-1].public_key='p4BGDwvXEG6qWcCFduPUcU71Kvdtn3TI1BIg0wdmdgk='
  # 对端连接点被设定在本地 127.0.0.1:3333（说明此处使用了 wstunnel 等工具进行了本地端口转发/封装）
  set network.@wireguard_wg0[-1].endpoint_host='127.0.0.1'
  set network.@wireguard_wg0[-1].endpoint_port='3333'
  # 保持长连接心跳，每 25 秒发一次包防止 NAT 墙阻断
  set network.@wireguard_wg0[-1].persistent_keepalive='25'
  # 自动向系统路由表注入下方的 allowed_ips 路由
  set network.@wireguard_wg0[-1].route_allowed_ips='1'
  
  # 声明通过此隧道可达的 Beverly 侧目标网段，一旦访问这些 IP，流量将被塞入隧道
  add_list network.@wireguard_wg0[-1].allowed_ips='10.0.0.1/32'
  add_list network.@wireguard_wg0[-1].allowed_ips='10.10.10.0/24'
  add_list network.@wireguard_wg0[-1].allowed_ips='192.168.12.0/24'
  add_list network.@wireguard_wg0[-1].allowed_ips='192.168.80.0/24'
  add_list network.@wireguard_wg0[-1].allowed_ips='192.168.90.0/24'

# 声明通过此隧道中转可达的 Riviera 侧目标核心业务网段 (星型架构借道)
  add_list network.@wireguard_wg0[-1].allowed_ips='10.0.0.2/32'
  add_list network.@wireguard_wg0[-1].allowed_ips='10.29.0.0/16'
EOF

uci commit network

# =============================================================================
# 15. 启用 PassWall2 开机自启
# =============================================================================
# 如果系统内安装了 passwall2 服务，则尝试启动它
if [ -x /etc/init.d/passwall2 ]; then
    /etc/init.d/passwall2 start
fi

# =============================================================================
# 16. 收尾清理
# =============================================================================

# 尝试主动关闭 wg0 接口，确保系统首次启动时隧道处于初始关闭状态（忽略报错）
ifdown wg0 2>/dev/null || true

# 删除此初始化脚本自身，确保后续重启不会重复执行这些配置
rm -f /etc/uci-defaults/zzz-default-settings

exit 0

# 20261006
