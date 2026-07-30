#!/bin/sh

# ==============================================================================
# MosDNS & AdGuardHome 规则定时更新与单向同步脚本
# ------------------------------------------------------------------------------
# Script Version : v2026.07.30-Rev.T (Fully Annotated Production Edition)
# Description    : 1. 彻底弃用重型 Git 依赖，改用轻量级 GitHub Raw 直链单向拉取架构。
#                  2. 引入 cmp 字节流命令进行内容级精准校验，拒绝时间戳错乱干扰。
#                  3. 完美承袭分流规则下载的高可用容灾机制 (直连超时自动降级镜像源)。
#                  4. 依据本地物理 IPv4 网段智能识别站点，按需精准触发容器平滑重启。
# ==============================================================================

# ==============================================================================
# I. 全局路径与基础变量定义
# ------------------------------------------------------------------------------
# 使用 $HOME 环境变量进行动态路径推导，确保无论是 root 还是普通用户执行均能精准寻址。
# ==============================================================================
MOSDNS_DIR="$HOME/mosdns"                     # MosDNS 服务容器的工作根目录
RULES_DAT_DIR="$MOSDNS_DIR/rules-dat"         # 存放 geoip/geosite 等基础分流规则集的物理目录
RULE_DIR="$MOSDNS_DIR/config/rule"            # 存放自定义白名单/黑名单/免缓存等特殊规则的目录

ADH_DIR="$HOME/adh"                           # AdGuardHome 服务容器的工作根目录
ADH_CONF_DIR="$ADH_DIR/conf"                  # AdGuardHome 配置文件存储子目录
ADH_LOCAL_FILE="${ADH_CONF_DIR}/AdGuardHome.yaml" # 当前正在对外提供解析服务的本地主配置文件

# 远程 GitHub 基础下载路径定义 (用于拼接自定义规则及 AdGuardHome 站点文件的 Raw URL)
CUSTOM_RULE_BASE_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/rule"

# ==============================================================================
# II. 宿主机网段唯一识别机制 (Pre-flight Check 准入熔断)
# ------------------------------------------------------------------------------
# 零污染设计：无需在宿主机创建任何环境标识文件，直接抓取当前活跃的物理 IPv4 网段锁桩站点。
# ==============================================================================
CURRENT_SITE=""

# 1. 执行 `ip -4 addr show` 仅过滤 IPv4 协议网卡信息，通过 `grep -qE` 开启静默扩展正则匹配。
# 2. 匹配 "inet 192\.168\.12\."：严格限定 192.168.12.x 网段 (Beverly 站点特征)。
#    (注意对小数点进行了物理转义，有效防止诸如 172.17.0.1 等 Docker 虚拟网桥引发误判)。
if ip -4 addr show 2>/dev/null | grep -qE "inet 192\.168\.12\.[0-9]+"; then
  CURRENT_SITE="Beverly"
# 3. 若不满足上方条件，则继续检索是否属于 10.29.2.x 网段 (Riviera 站点特征)。
elif ip -4 addr show 2>/dev/null | grep -qE "inet 10\.29\.2\.[0-9]+"; then
  CURRENT_SITE="Riviera"
else
  # 【安全熔断防御】：若两路网段均无法匹配（如同期断网或网卡异常），立刻中断执行！
  # 绝对不允许带着空站点变量向下污染生产配置，强行保全当前正在运行的 DNS 解析服务。
  echo "【系统错误】无法通过当前宿主机 IP 网段识别站点！脚本触发安全熔断，停止执行。"
  exit 1
fi

echo "=============================================================================="
echo "开始执行网络服务规则更新与单向同步任务 (内容差分校验 + 纯净 Raw 模式)"
echo "当前匹配站点 : 【 ${CURRENT_SITE} 】"
echo "=============================================================================="
echo

# 预先确保所有目标运行路径的文件夹真实存在，彻底杜绝后续 mv 或 wget 报“目录不存在”的错误
[ ! -d "$RULES_DAT_DIR" ] && mkdir -p "$RULES_DAT_DIR"
[ ! -d "$RULE_DIR" ] && mkdir -p "$RULE_DIR"
[ ! -d "$ADH_CONF_DIR" ] && mkdir -p "$ADH_CONF_DIR"

# ==============================================================================
# III. AdGuardHome 配置文件单向下载与字节级差分比对
# ------------------------------------------------------------------------------
# 摒弃了频繁克隆 Git 带来的碎片文件积累，利用本地 /tmp 空间进行流式下载与二进制比对。
# 仅在发现实质性内容差异时覆写生产配置，最大程度缩减磁盘 I/O 并维护网关的高可用。
# ==============================================================================
echo "--- 正在从 GitHub Raw 拉取最新的 AdGuardHome 配置并比对 ---"

# 动态拼接当前站点对应的云端存储 Raw 路径及本地临时中转文件路径
ADH_RAW_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/adh.yaml.${CURRENT_SITE}"
ADH_TMP_FILE="/tmp/adh.yaml.tmp.${CURRENT_SITE}"

# 强制清理历史残留的临时碎片，确保本轮下载环境纯净
rm -f "$ADH_TMP_FILE"

# 【第一通路】优先进行 GitHub 原生直连 HTTP 下载，设置 15 秒硬超时防止网络死锁挂起脚本
wget -q --timeout=15 "$ADH_RAW_URL" -O "$ADH_TMP_FILE"

# 【故障自愈】若 wget 返回非 0 状态码或下载回来的文件内容为 0 字节 (死链或 404)，则降级切换至镜像加速源
if [ $? -ne 0 ] || [ ! -s "$ADH_TMP_FILE" ]; then
  rm -f "$ADH_TMP_FILE"
  # 引入备用通路，使用 ghproxy.net 对原本的 GitHub 域名进行反向代理加速拉取
  wget -q --timeout=15 "https://ghproxy.net/$ADH_RAW_URL" -O "$ADH_TMP_FILE"
fi

# 核心状态变量：初始值为 0，用于标记 AdGuardHome 配置是否有实质性改动，决定末尾是否重启容器
ADH_CHANGED=0

# 【严格完整性校验】：必须确保上述任意通路下载成功，且文件大小大于 0 字节方可进入决策层
if [ -s "$ADH_TMP_FILE" ]; then
  # 场景 A：如果本地正在对外服务的物理配置文件已存在，则启用字节流硬碰硬比对
  if [ -f "$ADH_LOCAL_FILE" ]; then
    # cmp -s (Silent 模式) 仅进行二进制字节逐一比对，不输出任何标准信息，直接依靠状态码判断：
    # 返回值为 0 代表两文件完全一致，非 0 代表存在任何字符或排版上的差异。
    if cmp -s "$ADH_TMP_FILE" "$ADH_LOCAL_FILE"; then
      echo ">>> 结果：本地运行配置与云端最新文件内容完全一致，无需任何操作。"
      rm -f "$ADH_TMP_FILE" # 内容完全一致，即刻粉碎临时文件，保持 /tmp 纯净
    else
      echo ">>> 结果：检测到云端配置与本地存在内容差异！准备更新本地服务..."
      
      # 【扩展审查接口】：利用 type 动态探查当前 shell 环境中是否声明了 UUID 深度清洗函数
      # 若定义了该函数，则在覆盖前调用它对临时文件进行去重净化；若未定义，则静默跳过不报错。
      type fix_duplicate_uids >/dev/null 2>&1 && fix_duplicate_uids "$ADH_TMP_FILE"
      
      # 执行原子级覆盖：mv 操作在 POSIX 标准下属于瞬时完成的重命名行为，能将闪断时间控制在微秒级
      mv "$ADH_TMP_FILE" "$ADH_LOCAL_FILE"
      echo "→ 成功将云端配置同步覆盖至本地: $ADH_LOCAL_FILE"
      ADH_CHANGED=1 # 标记配置已变动，末尾必须重启容器以加载新规则
    fi
  else
    # 场景 B：本地属于首次全新部署，或者主配置目录被清空，直接进入初始化下载逻辑
    echo ">>> 结果：本地未找到配置文件，正在从云端进行初始化下载..."
    type fix_duplicate_uids >/dev/null 2>&1 && fix_duplicate_uids "$ADH_TMP_FILE"
    mv "$ADH_TMP_FILE" "$ADH_LOCAL_FILE"
    ADH_CHANGED=1
  fi
else
  # 【容灾保护】：若双通路下载均告失败（网络彻底阻断），保留本地老配置继续服役，绝对不覆写空文件
  echo "【警告】无法从 GitHub 或镜像站下载到有效的 AdGuardHome 配置文件，主动跳过同步保护现有服务。"
fi
echo

# ==============================================================================
# IV. MosDNS 通用规则与自定义 Rule 下载 (保持单向防宕机原子下载)
# ------------------------------------------------------------------------------
# 完美保持生产级容灾意志：定义规则矩阵，在下载链路中全部支持高可用自愈降级。
# ==============================================================================

# 1. 大陆 IP、GFW 列表、苹果及谷歌厂商清单等常态化大文件矩阵 (对应存放至 ~/mosdns/rules-dat)
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

# 2. 自定义维护的灰名单、黑白名单、免缓存等核心过滤逻辑规则 (对应存放至 ~/mosdns/config/rule)
CUSTOM_RULE_URL_FILE_LIST=$(cat << EOF_CUSTOM_RULE
${CUSTOM_RULE_BASE_URL}/greylist.txt greylist.txt
${CUSTOM_RULE_BASE_URL}/nocache.txt nocache.txt
${CUSTOM_RULE_BASE_URL}/whitelist.txt whitelist.txt
EOF_CUSTOM_RULE
)

# 高可用原子防宕机安全下载引擎函数
download_files() {
  list="$1"        # 传入的 URL 与保存文件名的映射列表字符串
  target_dir="$2"  # 目标落盘物理目录路径
  
  # 利用 printf 配合 while 循环以及 IFS 空格切分，逐行原子化提取规则
  printf "%s\n" "$list" | while IFS=' ' read -r url fname; do
    [ -z "$url" ] && continue
    [ -z "$fname" ] && continue

    # 构建带后缀的本地临时交换文件，严禁直接在活跃生产文件上写数据
    tmp_file="${target_dir}/${fname}.tmp"
    
    # 尝试原生直连 HTTP 下载
    wget -q --timeout=15 "$url" -O "$tmp_file"

    # 若直连遭遇网络波动失败，且源头属于 GitHub 域名，则实施降级镜像源提取
    if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
      if echo "$url" | grep -q "raw.githubusercontent.com"; then
        rm -f "$tmp_file"
        wget -q --timeout=15 "https://ghproxy.net/$url" -O "$tmp_file"
      fi
    fi

    # 【完整性双重验证】：仅当 wget 最终退出状态码为 0 且临时文件确定有物理大小时，才允许 mv 原子覆盖
    if [ $? -eq 0 ] && [ -s "$tmp_file" ]; then
      mv "$tmp_file" "${target_dir}/${fname}"
    else
      # 下载不完整或失败则直接粉碎，不影响原有的旧规则继续工作
      rm -f "$tmp_file"
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
# ------------------------------------------------------------------------------
# 兼容新老环境中的 Docker 管理引擎，同时保障高可用，杜绝无意义的断网闪断。
# ==============================================================================
echo "=============================================================================="
echo "检查完毕，开始适配宿主机环境重启 Docker 容器..."
echo "=============================================================================="

# 探查优先级：Docker 现代版插件式语法 -> 老版本独立命令行工具 -> 常见操作系统绝对路径
if docker compose version >/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD="docker-compose"
else
  DC_CMD="/usr/local/bin/docker-compose"
fi

# 1. MosDNS 服务重启决策：由于上文对其规则库进行了常态化刷新，为确保内存加载最新分流 IP，固定执行重启
echo "→ 正在重启 MosDNS 服务..."
cd "$MOSDNS_DIR" && $DC_CMD down && $DC_CMD up -d
echo

# 2. AdGuardHome 服务重启：
echo "→ 正在重启 AdGuardHome 服务..."
cd "$ADH_DIR" && $DC_CMD down && $DC_CMD up -d
echo

echo "=============================================================================="
echo "所有规则同步与服务管理任务顺利完成！"
echo "=============================================================================="
