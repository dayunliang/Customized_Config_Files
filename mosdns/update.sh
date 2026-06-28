#!/bin/sh

# ==============================================================================
# MosDNS & AdGuardHome 规则与配置定时更新脚本
# ------------------------------------------------------------------------------
# Script Version : v2026.06.28-Rev.D
# Modified Note  : 适配独立部署架构，分别进入 ~/mosdns 和 ~/adh 目录重启容器。
# ------------------------------------------------------------------------------
# 更新内容分为三类：
#
# 1. 通用规则文件：
#    保存到：~/mosdns/rules-dat
#
# 2. 自定义 MosDNS rule 文件：
#    保存到：~/mosdns/config/rule
#
# 3. AdGuardHome 配置文件：
#    保存到：~/adh/conf
# ==============================================================================

# 目录路径定义
MOSDNS_DIR="$HOME/mosdns"
RULES_DAT_DIR="$MOSDNS_DIR/rules-dat"
RULE_DIR="$MOSDNS_DIR/config/rule"

ADH_DIR="$HOME/adh"
ADH_CONF_DIR="$ADH_DIR/conf"

# 你的自定义规则文件所在的远程基础路径
CUSTOM_RULE_BASE_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/rule"

# ==============================================================================
# 目录初始化
# ==============================================================================

# 如果通用规则目录不存在，则自动创建
[ ! -d "$RULES_DAT_DIR" ] && mkdir -p "$RULES_DAT_DIR"

# 如果自定义 rule 目录不存在，则自动创建
[ ! -d "$RULE_DIR" ] && mkdir -p "$RULE_DIR"

# 如果 AdGuardHome 配置目录不存在，则自动创建
[ ! -d "$ADH_CONF_DIR" ] && mkdir -p "$ADH_CONF_DIR"

# ==============================================================================
# 1. 通用规则下载列表 (保存至 ~/mosdns/rules-dat)
# ------------------------------------------------------------------------------
# 格式：URL 文件名
# ==============================================================================
RULES_DAT_URL_FILE_LIST=$(cat << 'EOF_RULES_DAT'
https://raw.githubusercontent.com/17mon/china_ip_list/refs/heads/master/china_ip_list.txt geoip_cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt geosite_category-ads-all.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt geosite_geolocation-!cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt geosite_cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt geosite_gfw.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/china-list.txt geosite_cn_extra.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple-cn.txt geosite_cn_apple.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/google-cn.txt geosite_cn_google.txt
https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/rules-dat/hosts.txt hosts.txt
https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/rules-dat/geoip_private.txt geoip_private.txt
EOF_RULES_DAT
)

# ==============================================================================
# 2. 自定义 rule 文件下载列表 (保存至 ~/mosdns/config/rule)
# ==============================================================================
CUSTOM_RULE_URL_FILE_LIST=$(cat << EOF_CUSTOM_RULE
${CUSTOM_RULE_BASE_URL}/greylist.txt greylist.txt
${CUSTOM_RULE_BASE_URL}/nocache.txt nocache.txt
${CUSTOM_RULE_BASE_URL}/whitelist.txt whitelist.txt
EOF_CUSTOM_RULE
)

# ==============================================================================
# 3. AdGuardHome 配置文件下载列表 (保存至 ~/adh/conf)
# ==============================================================================
ADH_CONF_URL_FILE_LIST=$(cat << 'EOF_ADH_CONF'
https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/adh.yaml AdGuardHome.yaml
EOF_ADH_CONF
)

# ==============================================================================
# 统计下载列表中的有效行数
# ==============================================================================
count_list_items() {
  printf "%s\n" "$1" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

# ==============================================================================
# 下载函数
# ==============================================================================
download_files() {
  list="$1"
  target_dir="$2"
  display_name="$3"
  start_index="$4"
  total_files="$5"

  current_index="$start_index"

  echo "=============================================================================="
  echo "开始更新 ${display_name}"
  echo "保存目录：${target_dir}"
  echo "统一编号：从 ${start_index}/${total_files} 开始"
  echo "=============================================================================="
  echo

  printf "%s\n" "$list" | while IFS=' ' read -r url fname; do
    [ -z "$url" ] && continue
    [ -z "$fname" ] && continue

    echo "[${current_index}/${total_files}] Downloading ${fname}..."

    # 先下载到临时文件，下载成功后再覆盖正式文件。
    tmp_file="${target_dir}/${fname}.tmp"

    wget "$url" -O "$tmp_file"

    if [ $? -eq 0 ]; then
      mv "$tmp_file" "${target_dir}/${fname}"
      echo "→ Saved to ${target_dir}/${fname}"
    else
      rm -f "$tmp_file"
      echo "✗ Failed to download ${fname}"
      echo "  URL: ${url}"
    fi

    echo
    current_index=$((current_index + 1))
  done
}

# ==============================================================================
# 统一计算全部下载文件数量
# ==============================================================================
RULES_DAT_TOTAL=$(count_list_items "$RULES_DAT_URL_FILE_LIST")
CUSTOM_RULE_TOTAL=$(count_list_items "$CUSTOM_RULE_URL_FILE_LIST")
ADH_CONF_TOTAL=$(count_list_items "$ADH_CONF_URL_FILE_LIST")

TOTAL_FILES=$((RULES_DAT_TOTAL + CUSTOM_RULE_TOTAL + ADH_CONF_TOTAL))

echo "=============================================================================="
echo "独立网络服务规则与配置文件更新开始"
echo "Script Version : v2026.06.28-Rev.D"
echo "本次计划下载总数：${TOTAL_FILES} 个文件"
echo "rules-dat 文件数：${RULES_DAT_TOTAL}"
echo "自定义 rule 文件数：${CUSTOM_RULE_TOTAL}"
echo "AdGuardHome 配置文件数：${ADH_CONF_TOTAL}"
echo "=============================================================================="
echo

# 1. 更新通用规则文件到 ~/mosdns/rules-dat
download_files "$RULES_DAT_URL_FILE_LIST" "$RULES_DAT_DIR" "rules-dat 规则文件" 1 "$TOTAL_FILES"

# 2. 更新自定义 rule 文件到 ~/mosdns/config/rule
CUSTOM_RULE_START=$((RULES_DAT_TOTAL + 1))
download_files "$CUSTOM_RULE_URL_FILE_LIST" "$RULE_DIR" "MosDNS 自定义 rule 文件" "$CUSTOM_RULE_START" "$TOTAL_FILES"

# 3. 更新 AdGuardHome 配置文件到 ~/adh/conf
ADH_CONF_START=$((RULES_DAT_TOTAL + CUSTOM_RULE_TOTAL + 1))
download_files "$ADH_CONF_URL_FILE_LIST" "$ADH_CONF_DIR" "AdGuardHome 配置文件" "$ADH_CONF_START" "$TOTAL_FILES"

# ==============================================================================
# 分别切换目录重启独立的 Docker 容器服务
# ==============================================================================
echo "=============================================================================="
echo "文件下载更新完毕。开始分别重启对应的 Docker 容器..."
echo "=============================================================================="

# 重启 MosDNS 容器
echo "→ 正在重启 MosDNS 服务 (${MOSDNS_DIR})..."
cd "$MOSDNS_DIR" && docker-compose down && docker-compose up -d

echo

# 重启 AdGuardHome 容器
echo "→ 正在重启 AdGuardHome 服务 (${ADH_DIR})..."
cd "$ADH_DIR" && docker-compose down && docker-compose up -d

echo "=============================================================================="
echo "所有规则更新与容器重启任务已顺利完成！"
echo "rules-dat 目录 : ${RULES_DAT_DIR}"
echo "rule 目录      : ${RULE_DIR}"
echo "adh conf 目录  : ${ADH_CONF_DIR}"
echo "=============================================================================="
