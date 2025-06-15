#!/bin/sh

# 定义 MosDNS 项目目录和 rule 子目录
MOSDNS_DIR="$HOME/mosdns"
RULE_DIR="$MOSDNS_DIR/rule"

# 如果 ~/mosdns/rule 不存在，则创建该目录
if [ ! -d "$RULE_DIR" ]; then
  mkdir -p "$RULE_DIR"
fi

# 下载最新的 IP 和域名列表到 rule 目录
wget https://cdn.jsdelivr.net/gh/17mon/china_ip_list@master/china_ip_list.txt \
     -O "$RULE_DIR/geoip_cn.txt" > /dev/null 2>&1

wget https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/reject-list.txt \
     -O "$RULE_DIR/geosite_category-ads-all.txt" > /dev/null 2>&1

wget https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/proxy-list.txt \
     -O "$RULE_DIR/geosite_geolocation-!cn.txt" > /dev/null 2>&1

wget https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/direct-list.txt \
     -O "$RULE_DIR/geosite_cn.txt" > /dev/null 2>&1

echo "Update geoip & geosite lists completed."
