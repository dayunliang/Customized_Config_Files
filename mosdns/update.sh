#!/bin/sh

# ==============================================================================
# MosDNS & AdGuardHome 规则与配置定时更新脚本
# ------------------------------------------------------------------------------
# Script Version : v2026.07.26-Rev.G (Pure IP-Based Detection)
# Modified Note  : 仅保留宿主机 IPv4 物理网段作为唯一站点判别标准，极致精简。
#                  适配 crontab 无人值守环境，包含完整的原子下载与容器重启逻辑。
# ==============================================================================

# 目录路径定义 (基于用户家目录动态推导，兼容 root 与普通用户)
MOSDNS_DIR="$HOME/mosdns"
RULES_DAT_DIR="$MOSDNS_DIR/rules-dat"
RULE_DIR="$MOSDNS_DIR/config/rule"

ADH_DIR="$HOME/adh"
ADH_CONF_DIR="$ADH_DIR/conf"

# 远程的基础下载路径定义 (如 GitHub 仓库分支或组织变更，仅需修改此处)
CUSTOM_RULE_BASE_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/rule"
ADH_CONF_BASE_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf"

# ==============================================================================
# 0. 宿主机网段唯一识别机制 (Pre-flight Check 准入关卡)
# ------------------------------------------------------------------------------
# 通过 `ip -4 addr show` 获取宿主机物理网卡 IPv4 地址，精准匹配子网。
# 使用正则匹配，确保避开 Docker 虚拟网卡 (如 172.17.x.x) 的干扰。
# ==============================================================================
CURRENT_SITE=""

# 匹配 Beverly 站点：192.168.12.0/24 网段
if ip -4 addr show 2>/dev/null | grep -qE "inet 192\.168\.12\.[0-9]+"; then
  CURRENT_SITE="Beverly"
# 匹配 Riviera 站点：10.29.2.0/24 网段
elif ip -4 addr show 2>/dev/null | grep -qE "inet 10\.29\.2\.[0-9]+"; then
  CURRENT_SITE="Riviera"
else
  # 熔断机制：如果网段不匹配，立即退出，绝对不向下执行破坏现有 DNS 配置
  echo "【系统错误】无法通过当前宿主机 IP 网段识别站点！"
  echo "当前主机 IPv4 地址不属于 Beverly (192.168.12.0/24) 或 Riviera (10.29.2.0/24)。"
  echo "安全熔断触发，脚本停止执行。"
  exit 1
fi

# ==============================================================================
# 目录初始化 (如果不存在则自动创建，保证脚本容错率)
# ==============================================================================
[ ! -d "$RULES_DAT_DIR" ] && mkdir -p "$RULES_DAT_DIR"
[ ! -d "$RULE_DIR" ] && mkdir -p "$RULE_DIR"
[ ! -d "$ADH_CONF_DIR" ] && mkdir -p "$ADH_CONF_DIR"

# ==============================================================================
# 1. 通用规则下载列表 (保存至 ~/mosdns/rules-dat)
# ------------------------------------------------------------------------------
# 格式：下载链接 目标文件名 (以空格分隔)
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
# 3. 动态 AdGuardHome 配置文件下载列表 (根据识别到的网段动态拼接)
# ------------------------------------------------------------------------------
# 无论远程文件名叫 adh.yaml.Beverly 还是 adh.yaml.Riviera，
# 下载到本地后统一重命名为 AdGuardHome.yaml，契合 Docker 容器配置挂载。
# ==============================================================================
ADH_CONF_URL_FILE_LIST=$(cat << EOF_ADH_CONF
${ADH_CONF_BASE_URL}/adh.yaml.${CURRENT_SITE} AdGuardHome.yaml
EOF_ADH_CONF
)

# ==============================================================================
# 统计下载列表中的有效行数 (过滤空行与空格)
# ==============================================================================
count_list_items() {
  printf "%s\n" "$1" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

# ==============================================================================
# 核心下载函数 (采用防宕机原子下载机制)
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

    # 1. 临时文件命名：先下载至 .tmp 文件，防止由于下载中断导致原配置文件损坏
    tmp_file="${target_dir}/${fname}.tmp"

    # 2. 静默模式 + 15秒超时：防止 crontab 日志爆满，防止网络卡死引发无限挂起
    wget -q --timeout=15 "$url" -O "$tmp_file"

    # 3. 严格验证：判断下载命令返回值 ($? -eq 0) 且 检查文件大小大于0字节 ([ -s ])
    if [ $? -eq 0 ] && [ -s "$tmp_file" ]; then
      # 原子覆盖：只有校验通过，才会瞬间替换正式生效的文件
      mv "$tmp_file" "${target_dir}/${fname}"
      echo "→ Saved to ${target_dir}/${fname}"
    else
      # 异常清理：下载失败或得到 0 字节文件时，删掉临时文件，保留旧文件继续提供服务
      rm -f "$tmp_file"
      echo "✗ Failed to download ${fname} (or file is empty/timeout)"
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
echo "独立网络服务规则与配置文件定时更新任务 (Host OS Mode)"
echo "Script Version : v2026.07.26-Rev.G"
echo "当前匹配站点   : 【 ${CURRENT_SITE} 】"
echo "本次计划下载总数：${TOTAL_FILES} 个文件"
echo "rules-dat 文件数：${RULES_DAT_TOTAL}"
echo "自定义 rule 文件数：${CUSTOM_RULE_TOTAL}"
echo "AdGuardHome 配置文件数：${ADH_CONF_TOTAL} (自动匹配 ${CURRENT_SITE} 专版)"
echo "=============================================================================="
echo

# 1. 更新通用规则文件到 ~/mosdns/rules-dat
download_files "$RULES_DAT_URL_FILE_LIST" "$RULES_DAT_DIR" "rules-dat 规则文件" 1 "$TOTAL_FILES"

# 2. 更新自定义 rule 文件到 ~/mosdns/config/rule
CUSTOM_RULE_START=$((RULES_DAT_TOTAL + 1))
download_files "$CUSTOM_RULE_URL_FILE_LIST" "$RULE_DIR" "MosDNS 自定义 rule 文件" "$CUSTOM_RULE_START" "$TOTAL_FILES"

# 3. 更新 AdGuardHome 配置文件到 ~/adh/conf
ADH_CONF_START=$((RULES_DAT_TOTAL + CUSTOM_RULE_TOTAL + 1))
download_files "$ADH_CONF_URL_FILE_LIST" "$ADH_CONF_DIR" "AdGuardHome 配置文件 (${CURRENT_SITE})" "$ADH_CONF_START" "$TOTAL_FILES"

# ==============================================================================
# 宿主机环境 Docker Compose 智能适配与容器重启
# ------------------------------------------------------------------------------
# 由于 crontab 运行时环境变量极简，直接执行 docker-compose 常报错 command not found。
# 此处按优先级自适应探查命令语法和绝对路径，确保无误重启。
# ==============================================================================
echo "=============================================================================="
echo "文件下载更新完毕。在宿主机开始分别重启对应的 Docker 容器..."
echo "=============================================================================="

# 探查优先级：官方新版插件语法 -> 系统全局命令 -> 常见安装绝对路径
if docker compose version >/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD="docker-compose"
elif [ -f "/usr/local/bin/docker-compose" ]; then
  DC_CMD="/usr/local/bin/docker-compose"
else
  echo "【系统错误】在宿主机上未找到 docker-compose 或 docker compose 命令！请检查系统 PATH。"
  exit 1
fi

# 重启 MosDNS 容器
echo "→ 正在使用 [ ${DC_CMD} ] 重启 MosDNS 服务 (${MOSDNS_DIR})..."
cd "$MOSDNS_DIR" && $DC_CMD down && $DC_CMD up -d

echo

# 重启 AdGuardHome 容器
echo "→ 正在使用 [ ${DC_CMD} ] 重启 AdGuardHome 服务 (${ADH_DIR})..."
cd "$ADH_DIR" && $DC_CMD down && $DC_CMD up -d

echo "=============================================================================="
echo "所有规则更新与宿主机容器重启任务已顺利完成！(当前生效站点: ${CURRENT_SITE})"
echo "rules-dat 目录 : ${RULES_DAT_DIR}"
echo "rule 目录      : ${RULE_DIR}"
echo "adh conf 目录  : ${ADH_CONF_DIR}"
echo "=============================================================================="
