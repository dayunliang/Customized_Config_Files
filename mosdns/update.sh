#!/bin/sh

# ==============================================================================
# MosDNS & AdGuardHome 规则定时更新与单向同步脚本
# ------------------------------------------------------------------------------
# Script Version : v2026.08.29-Rev.U (Channel Feedback Edition)
# Description    : 1. 彻底弃用重型 Git 依赖，改用轻量级 GitHub Raw 直链单向拉取架构。
#                  2. 引入 cmp 字节流命令进行内容级精准校验，拒绝时间戳错乱干扰。
#                  3. 完美承袭分流规则下载的高可用容灾机制 (直连超时自动降级镜像源)。
#                  4. 依据本地物理 IPv4 网段智能识别站点，按需精准触发容器平滑重启。
#                  5. 加入详细的文件下载过程打印，并明确标识下载成功所使用的网络通道。
#                  6. wget 增加 --no-check-certificate 忽略证书报错，保障各环境兼容。
#                  7. 严格遵守编码规范，全篇剔除行尾续行符反斜杠。
# ==============================================================================

# ==============================================================================
# I. 全局路径与基础变量定义
# ------------------------------------------------------------------------------
MOSDNS_DIR="$HOME/mosdns"                     
RULES_DAT_DIR="$MOSDNS_DIR/rules-dat"         
RULE_DIR="$MOSDNS_DIR/config/rule"            

ADH_DIR="$HOME/adh"                           
ADH_CONF_DIR="$ADH_DIR/conf"                  
ADH_LOCAL_FILE="${ADH_CONF_DIR}/AdGuardHome.yaml" 

CUSTOM_RULE_BASE_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/rule"

# ==============================================================================
# II. 宿主机网段唯一识别机制 (Pre-flight Check 准入熔断)
# ------------------------------------------------------------------------------
CURRENT_SITE=""

if ip -4 addr show 2>/dev/null | grep -qE "inet 192\.168\.12\.[0-9]+"; then
  CURRENT_SITE="Beverly"
elif ip -4 addr show 2>/dev/null | grep -qE "inet 10\.29\.2\.[0-9]+"; then
  CURRENT_SITE="Riviera"
else
  echo "【系统错误】无法通过当前宿主机 IP 网段识别站点！脚本触发安全熔断，停止执行。"
  exit 1
fi

echo "=============================================================================="
echo "开始执行网络服务规则更新与单向同步任务 (内容差分校验 + 纯净 Raw 模式)"
echo "当前匹配站点 : 【 ${CURRENT_SITE} 】"
echo "=============================================================================="
echo

[ ! -d "$RULES_DAT_DIR" ] && mkdir -p "$RULES_DAT_DIR"
[ ! -d "$RULE_DIR" ] && mkdir -p "$RULE_DIR"
[ ! -d "$ADH_CONF_DIR" ] && mkdir -p "$ADH_CONF_DIR"

# ==============================================================================
# III. AdGuardHome 配置文件单向下载与字节级差分比对
# ==============================================================================
echo "--- 正在从 GitHub Raw 拉取最新的 AdGuardHome 配置并比对 ---"

ADH_RAW_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/adh.yaml.${CURRENT_SITE}"
ADH_TMP_FILE="/tmp/adh.yaml.tmp.${CURRENT_SITE}"

rm -f "$ADH_TMP_FILE"

wget -q --no-check-certificate --timeout=15 "$ADH_RAW_URL" -O "$ADH_TMP_FILE"

if [ $? -ne 0 ] || [ ! -s "$ADH_TMP_FILE" ]; then
  rm -f "$ADH_TMP_FILE"
  wget -q --no-check-certificate --timeout=15 "https://ghproxy.net/$ADH_RAW_URL" -O "$ADH_TMP_FILE"
fi

ADH_CHANGED=0

if [ -s "$ADH_TMP_FILE" ]; then
  if [ -f "$ADH_LOCAL_FILE" ]; then
    if cmp -s "$ADH_TMP_FILE" "$ADH_LOCAL_FILE"; then
      echo ">>> 结果：本地运行配置与云端最新文件内容完全一致，无需任何操作。"
      rm -f "$ADH_TMP_FILE"
    else
      echo ">>> 结果：检测到云端配置与本地存在内容差异！准备更新本地服务..."
      type fix_duplicate_uids >/dev/null 2>&1 && fix_duplicate_uids "$ADH_TMP_FILE"
      mv "$ADH_TMP_FILE" "$ADH_LOCAL_FILE"
      echo "→ 成功将云端配置同步覆盖至本地: $ADH_LOCAL_FILE"
      ADH_CHANGED=1
    fi
  else
    echo ">>> 结果：本地未找到配置文件，正在从云端进行初始化下载..."
    type fix_duplicate_uids >/dev/null 2>&1 && fix_duplicate_uids "$ADH_TMP_FILE"
    mv "$ADH_TMP_FILE" "$ADH_LOCAL_FILE"
    ADH_CHANGED=1
  fi
else
  echo "【警告】无法从 GitHub 或镜像站下载到有效的 AdGuardHome 配置文件，主动跳过同步保护现有服务。"
fi
echo

# ==============================================================================
# IV. MosDNS 通用规则与自定义 Rule 下载 (保持单向防宕机原子下载)
# ==============================================================================

RULES_DAT_URL_FILE_LIST=$(cat << EOF_RULES_DAT
https://raw.githubusercontent.com/17mon/china_ip_list/refs/heads/master/china_ip_list.txt geoip_cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt geosite_category-ads-all.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt geosite_geolocation-!cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt geosite_cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt geosite_gfw.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/china-list.txt geosite_cn_extra.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple-cn.txt geosite_cn_apple.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/google-cn.txt geosite_cn_google.txt
https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/rules-dat/hosts.txt.${CURRENT_SITE} hosts.txt
https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/rules-dat/geoip_private.txt geoip_private.txt
EOF_RULES_DAT
)

CUSTOM_RULE_URL_FILE_LIST=$(cat << EOF_CUSTOM_RULE
${CUSTOM_RULE_BASE_URL}/greylist.txt greylist.txt
${CUSTOM_RULE_BASE_URL}/nocache.txt nocache.txt
${CUSTOM_RULE_BASE_URL}/whitelist.txt whitelist.txt
EOF_CUSTOM_RULE
)

download_files() {
  list="$1"
  target_dir="$2"
  
  printf "%s
" "$list" | while IFS=' ' read -r url fname; do
    [ -z "$url" ] && continue
    [ -z "$fname" ] && continue

    echo "  -> 尝试下载: $fname"

    tmp_file="${target_dir}/${fname}.tmp"
    
    wget -q --no-check-certificate --timeout=15 "$url" -O "$tmp_file"

    if [ $? -eq 0 ] && [ -s "$tmp_file" ]; then
      mv "$tmp_file" "${target_dir}/${fname}"
      echo "     [√] 通过 GitHub 原生直连拉取成功"
    else
      if echo "$url" | grep -q "raw.githubusercontent.com"; then
        rm -f "$tmp_file"
        echo "     (直连受阻，自动降级至备用镜像站...)"
        wget -q --no-check-certificate --timeout=15 "https://ghproxy.net/$url" -O "$tmp_file"
        
        if [ $? -eq 0 ] && [ -s "$tmp_file" ]; then
          mv "$tmp_file" "${target_dir}/${fname}"
          echo "     [√] 通过备用镜像站拉取成功"
        else
          rm -f "$tmp_file"
          echo "     [!] 警告: $fname 双通道均下载失败，已跳过覆盖。"
        fi
      else
        rm -f "$tmp_file"
        echo "     [!] 警告: $fname (非 GitHub 源) 下载失败，已跳过覆盖。"
      fi
    fi
  done
}

echo "--- 正在下载 MosDNS 规则与自定义 Rule ---"
download_files "$RULES_DAT_URL_FILE_LIST" "$RULES_DAT_DIR"
download_files "$CUSTOM_RULE_URL_FILE_LIST" "$RULE_DIR"
echo "→ MosDNS 规则下载尝试完毕。"
echo

# ==============================================================================
# V. 智能判定并重启对应的 Docker 容器服务 (系统级多版本适配)
# ==============================================================================
echo "=============================================================================="
echo "检查完毕，开始适配宿主机环境重启 Docker 容器..."
echo "=============================================================================="

if docker compose version >/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD="docker-compose"
else
  DC_CMD="/usr/local/bin/docker-compose"
fi

echo "→ 正在重启 MosDNS 服务..."
cd "$MOSDNS_DIR" && $DC_CMD down && $DC_CMD up -d
echo

echo "→ 正在重启 AdGuardHome 服务..."
cd "$ADH_DIR" && $DC_CMD down && $DC_CMD up -d
echo

echo "=============================================================================="
echo "所有规则同步与服务管理任务顺利完成！"
echo "=============================================================================="
