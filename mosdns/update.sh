#!/bin/sh

# ==============================================================================
# MosDNS 规则文件定时更新脚本
# ------------------------------------------------------------------------------
# Script Version : v2026.06.07-Rev.B
# Last Modified  : 2026-06-07 11:50:46
# Modified Note  : 新增自定义 rule 文件下载，并将全部下载文件改为统一编号。
# ------------------------------------------------------------------------------
# 更新内容分为两类：
#
# 1. 通用规则文件：
#    保存到：
#      ~/mosdns/rules-dat
#
# 2. 自定义 MosDNS rule 文件：
#    保存到：
#      ~/mosdns/config/rule
#
#    当前包含：
#      greylist.txt
#      nocache.txt
#      whitelist.txt
#
# 本版本特点：
#   1. 脚本头部记录脚本版本与最后修改时间，方便以后区分脚本内容版本。
#   2. 所有下载文件使用统一编号，例如 [1/11]、[2/11] ... [11/11]。
#   3. 下载逻辑保持原样：先下载到 .tmp，成功后再覆盖正式文件。
#      不做远程 / 本地差异统计，不判断新增或减少条数。
#
# 注意：
#   如果 greylist.txt、nocache.txt、whitelist.txt 实际不在下面的
#   CUSTOM_RULE_BASE_URL 路径下，只需要修改 CUSTOM_RULE_BASE_URL 即可。
# ==============================================================================

# MosDNS 项目根目录
MOSDNS_DIR="$HOME/mosdns"

# Loyalsoldier / 17mon 等通用规则文件保存目录
RULES_DAT_DIR="$MOSDNS_DIR/rules-dat"

# MosDNS 自定义 rule 文件保存目录
RULE_DIR="$MOSDNS_DIR/config/rule"

# 你的自定义规则文件所在的远程基础路径
# 这里按你之前常用的 Customized_Config_Files 仓库路径写法预设。
CUSTOM_RULE_BASE_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/rule"

# ==============================================================================
# 目录初始化
# ==============================================================================

# 如果通用规则目录不存在，则自动创建
[ ! -d "$RULES_DAT_DIR" ] && mkdir -p "$RULES_DAT_DIR"

# 如果自定义 rule 目录不存在，则自动创建
[ ! -d "$RULE_DIR" ] && mkdir -p "$RULE_DIR"

# ==============================================================================
# 通用规则下载列表
# ------------------------------------------------------------------------------
# 格式：
#   URL 文件名
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
# 自定义 rule 文件下载列表
# ------------------------------------------------------------------------------
# 这 3 个文件会保存到：
#   ~/mosdns/config/rule
# ==============================================================================
CUSTOM_RULE_URL_FILE_LIST=$(cat << EOF_CUSTOM_RULE
${CUSTOM_RULE_BASE_URL}/greylist.txt greylist.txt
${CUSTOM_RULE_BASE_URL}/nocache.txt nocache.txt
${CUSTOM_RULE_BASE_URL}/whitelist.txt whitelist.txt
EOF_CUSTOM_RULE
)

# ==============================================================================
# 统计下载列表中的有效行数
# ==============================================================================
count_list_items() {
  printf "%s
" "$1" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

# ==============================================================================
# 下载函数
# ------------------------------------------------------------------------------
# 参数说明：
#   $1 = 下载列表
#   $2 = 保存目录
#   $3 = 显示名称
#   $4 = 起始编号
#   $5 = 全部文件总数
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

  printf "%s
" "$list" | while IFS=' ' read -r url fname; do
    [ -z "$url" ] && continue
    [ -z "$fname" ] && continue

    echo "[${current_index}/${total_files}] Downloading ${fname}..."

    # 先下载到临时文件，下载成功后再覆盖正式文件。
    # 这样可以避免网络中断时把原本可用的旧规则文件覆盖成损坏文件。
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
# ------------------------------------------------------------------------------
# 注意：
#   这里不是写死 11，而是根据两个下载列表自动统计。
#   以后如果继续增加文件，编号总数会自动变化。
# ==============================================================================
RULES_DAT_TOTAL=$(count_list_items "$RULES_DAT_URL_FILE_LIST")
CUSTOM_RULE_TOTAL=$(count_list_items "$CUSTOM_RULE_URL_FILE_LIST")
TOTAL_FILES=$((RULES_DAT_TOTAL + CUSTOM_RULE_TOTAL))

echo "=============================================================================="
echo "MosDNS 规则文件更新开始"
echo "Script Version : v2026.06.07-Rev.B"
echo "Last Modified  : 2026-06-07 12:50:46 Beijing Time UTC+8"
echo "本次计划下载总数：${TOTAL_FILES} 个文件"
echo "rules-dat 文件数：${RULES_DAT_TOTAL}"
echo "自定义 rule 文件数：${CUSTOM_RULE_TOTAL}"
echo "=============================================================================="
echo

# 更新通用规则文件到 ~/mosdns/rules-dat
# 编号范围通常是：[1/11] 到 [8/11]
download_files "$RULES_DAT_URL_FILE_LIST" "$RULES_DAT_DIR" "rules-dat 规则文件" 1 "$TOTAL_FILES"

# 更新自定义 rule 文件到 ~/mosdns/config/rule
# 编号范围通常是：[9/11] 到 [11/11]
CUSTOM_RULE_START=$((RULES_DAT_TOTAL + 1))
download_files "$CUSTOM_RULE_URL_FILE_LIST" "$RULE_DIR" "MosDNS 自定义 rule 文件" "$CUSTOM_RULE_START" "$TOTAL_FILES"

echo "=============================================================================="
echo "All lists updated."
echo "rules-dat directory : ${RULES_DAT_DIR}"
echo "rule directory      : ${RULE_DIR}"
echo "=============================================================================="
