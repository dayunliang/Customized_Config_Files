#!/bin/sh

# MosDNS 项目目录和 rule 子目录
MOSDNS_DIR="$HOME/mosdns"
RULE_DIR="$MOSDNS_DIR/rule"

# 如果 rule 目录不存在则创建
[ ! -d "$RULE_DIR" ] && mkdir -p "$RULE_DIR"

# 在此处维护“URL 文件名”对，每行一个，URL 和对应文件以空格分隔
URL_FILE_LIST=$(cat << 'EOF'
https://cdn.jsdelivr.net/gh/17mon/china_ip_list@master/china_ip_list.txt geoip_cn.txt
https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/reject-list.txt geosite_category-ads-all.txt
https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/proxy-list.txt geosite_geolocation-!cn.txt
https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/direct-list.txt geosite_cn.txt
https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/gfw.txt geosite_gfw.txt
EOF
)

# 计算总行数（文件对数）
TOTAL=$(printf "%s\n" "$URL_FILE_LIST" | wc -l | tr -d ' ')

i=1
printf "%s\n" "$URL_FILE_LIST" | while IFS=' ' read -r url fname; do
  echo "[${i}/${TOTAL}] Downloading ${fname}..."
  # BusyBox wget 默认会显示点状进度，这里不重定向，保留进度输出
  wget "$url" -O "$RULE_DIR/$fname"
  if [ $? -eq 0 ]; then
    echo "→ Saved to ${RULE_DIR}/${fname}"
  else
    echo "✗ Failed to download ${fname}"
  fi
  echo
  i=$((i + 1))
done

echo "All lists updated in ${RULE_DIR}."
