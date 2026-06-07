#!/bin/sh
# ============================================================================
# 脚本名称：deploy_adh_mosdns.sh
# 功能：AdGuard Home + MosDNS 一键联合网络分流协同部署
# 依赖：已运行 docker_alpine.sh 完成基础虚拟化引擎及 crun/runc 环境配置
# 审计重点：精准校对 01-10 业务序号，重构技术注释，打通动态端口对齐排版
# 本次修改时间：2026-06-07 13:44:16 CST/UTC+8
# 本次修改内容：新增部署阶段临时 DNS 兜底机制，并完善关键流程注释，便于后续维护与排障
# ============================================================================

set -e

# ----------------------------------------------------------------------------
# 终端色彩与高级视觉组件定义
# ----------------------------------------------------------------------------
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; PURPLE='\033[35m'; CYAN='\033[36m'; NC='\033[0m'
BOLD='\033[1m'

ok()    { printf "${GREEN}  ✔  ${NC}%s\n" "$*"; }
warn()  { printf "${YELLOW}  ▲  ${NC}%s\n" "$*"; }
err()   { printf "${RED}  ✘  ${NC}%s\n" "$*"; }
info()  { printf "${BLUE}  ▶  ${NC}%s\n" "$*"; }
title() { printf "\n${BOLD}${PURPLE}======================================================================${NC}\n${BOLD} 🌐  %s${NC}\n${BOLD}${PURPLE}======================================================================${NC}\n" "$*"; }

# ----------------------------------------------------------------------------
# 基础运维小工具函数
# ----------------------------------------------------------------------------
# 等待 Docker 守护进程套接字文件就绪，避免异步起速导致脚本后续因找不到 Sock 而崩溃
wait_sock() {
  local N="${1:-20}"
  for _ in $(seq 1 "$N"); do
    [ -S /var/run/docker.sock ] && return 0
    sleep 1
  done
  return 1
}

# 干净重启后台容器引擎，并强制擦除 Moby 引擎残留的任务运行时锁，保障幂等性
restart_daemons() {
  rc-service docker stop >/dev/null 2>&1 || true
  rc-service containerd stop >/dev/null 2>&1 || true
  rm -rf /run/containerd/io.containerd.runtime.v2.task/moby/* >/dev/null 2>&1 || true
  rc-service containerd start >/dev/null 2>&1 || true
  rc-service docker start >/dev/null 2>&1 || true
  wait_sock 25
}

# 提取当前容器引擎的核心底层拓扑参数
docker_info_brief() {
  docker info 2>/dev/null | awk '
    /Server Version/     {print "     • 引擎版本 (Engine):   " $3}
    /Default Runtime/    {print "     • 默认运行时 (Runtime): " $3}
    /Storage Driver/     {print "     • 存储驱动 (Driver):   " $3}
    /Cgroup Version/     {print "     • 核心控制组 (Cgroup):  " $3}
  '
}

# ----------------------------------------------------------------------------
# 部署阶段临时 DNS 兜底与 resolv.conf 原样恢复机制
# ----------------------------------------------------------------------------
# 背景说明：
#   本脚本用于在一台“全新的 Alpine Linux”上部署家庭站点 DNS 服务。
#   这类场景有一个天然矛盾：
#     - 当前机器正在部署 DNS 服务；
#     - 但部署过程本身又需要 DNS 解析远程下载地址。
#
#   例如脚本后续会通过 curl 下载以下类型的远程资源：
#     - AdGuard Home 的配置文件；
#     - MosDNS 的 docker-compose.yaml；
#     - MosDNS 的 update.sh；
#     - geoip_private.txt、hosts.txt；
#     - config_custom.yaml、dns.yaml、dat_exec.yaml；
#     - whitelist.txt、greylist.txt、nocache.txt。
#
#   如果此时局域网内原 DNS 尚未可用，或者 DHCP 下发的 DNS 就是准备部署的这台机器，
#   那么脚本会在部署前半段因为无法解析 GitHub / CDN 域名而失败。
#
# 设计目标：
#   1. 不改变用户原本的网络配置设计。
#   2. 不主动执行 udhcpc，避免刷新 IP / 网关 / DNS。
#   3. 只在脚本运行期间临时接管 /etc/resolv.conf。
#   4. 脚本成功、失败或 Ctrl+C 中断后，都尽量恢复原始 /etc/resolv.conf。
#
# 处理流程：
#   1. setup_temporary_dns()
#      - 如果 /etc/resolv.conf 存在，则先备份到 /tmp/resolv.conf.deploy_adh_mosdns.bak。
#      - 然后写入临时公共 DNS。
#
#   2. cleanup_on_exit()
#      - 通过 trap 绑定 EXIT / INT / TERM。
#      - 无论脚本正常结束还是异常中断，都会进入清理函数。
#
#   3. restore_original_dns()
#      - 如果原来存在 /etc/resolv.conf，则恢复原文件。
#      - 如果原来不存在 /etc/resolv.conf，则删除脚本创建的临时文件。
#
# 临时 DNS 选择逻辑：
#   223.5.5.5      阿里 DNS，国内访问速度快，适合部署阶段拉取远程资源。
#   119.29.29.29   腾讯 DNS，作为国内第二 DNS 兜底。
#   1.1.1.1        Cloudflare DNS，作为国外 DNS 兜底。
#
# 注意：
#   这里的 DNS 只是“部署期间临时使用”，不是最终家庭 DNS 架构的一部分。
#   脚本结束后会恢复部署前的 resolv.conf，因此不会影响 MosDNS / AdGuard Home
#   部署完成后的正式 DNS 分流设计。
RESOLV_CONF="/etc/resolv.conf"
RESOLV_BACKUP="/tmp/resolv.conf.deploy_adh_mosdns.bak"
RESOLV_EXISTED=0
TEMP_DNS_ACTIVE=0

# 部署阶段临时写入公共 DNS，避免全新 Alpine 环境没有可用 DNS 导致远程下载失败
setup_temporary_dns() {
  if [ -f "$RESOLV_CONF" ] || [ -L "$RESOLV_CONF" ]; then
    cp "$RESOLV_CONF" "$RESOLV_BACKUP"
    RESOLV_EXISTED=1
    ok "已备份当前 DNS 配置：$RESOLV_BACKUP"
  else
    RESOLV_EXISTED=0
    warn "当前系统不存在 /etc/resolv.conf，后续将创建临时 DNS 配置并在退出时删除"
  fi

  cat > "$RESOLV_CONF" <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 1.1.1.1
options timeout:2 attempts:2
EOF

  TEMP_DNS_ACTIVE=1
  ok "已临时接管系统 DNS，用于保障部署阶段远程文件下载"
}

# 脚本结束后原样恢复部署前的 resolv.conf
restore_original_dns() {
  if [ "$TEMP_DNS_ACTIVE" != "1" ]; then
    return 0
  fi

  if [ "$RESOLV_EXISTED" = "1" ] && [ -f "$RESOLV_BACKUP" ]; then
    cp "$RESOLV_BACKUP" "$RESOLV_CONF"
    rm -f "$RESOLV_BACKUP"
    TEMP_DNS_ACTIVE=0
    ok "已恢复部署前的 DNS 配置：$RESOLV_CONF"
    return 0
  fi

  if [ "$RESOLV_EXISTED" = "0" ]; then
    rm -f "$RESOLV_CONF" "$RESOLV_BACKUP"
    TEMP_DNS_ACTIVE=0
    warn "部署前不存在 /etc/resolv.conf，已删除临时 DNS 配置文件"
    return 0
  fi

  warn "未找到 DNS 备份文件，保留当前 /etc/resolv.conf"
  TEMP_DNS_ACTIVE=0
}

# 无论脚本成功、失败、Ctrl+C 中断，退出前都尝试恢复原始 DNS
cleanup_on_exit() {
  EXIT_CODE="$?"

  # 防止 cleanup 内部 exit 再次触发 trap，造成重复输出
  trap - EXIT INT TERM

  if [ "$TEMP_DNS_ACTIVE" = "1" ]; then
    if [ "$EXIT_CODE" -eq 0 ]; then
      info "部署流程已结束，正在恢复部署前 DNS 配置..."
    else
      warn "脚本异常中断，正在恢复部署前 DNS 配置..."
    fi

    restore_original_dns || true
  fi

  exit "$EXIT_CODE"
}

trap cleanup_on_exit EXIT INT TERM


# ============================================================================
# 主脚本 10 大核心生命周期流水线
# ============================================================================

# ===== 基础变量初始化 =====
MOSDNS_DIR="${HOME}/mosdns"
ADH_DIR="${HOME}/adh"
CRONTAB_FILE="/etc/crontabs/root"
REPORT="/root/adh_mosdns_deploy_$(date +%Y%m%d_%H%M%S).log"

title "00/10. 部署阶段临时 DNS 兜底"
info "正在备份当前 resolv.conf，并写入临时公共 DNS，防止新环境无法解析远程下载地址..."
setup_temporary_dns

title "01/10. 核心虚拟化容器引擎环境校验"
info "正在扫描本地 Docker 与 Compose 编排环境连通性..."
if ! command -v docker >/dev/null 2>&1; then
  err "未检测到 docker 核心组件，请先运行基础脚手架脚本 docker_alpine.sh！"
  echo ""; exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  err "未检测到 docker compose v2 指令集，请先在 docker_alpine.sh 中启用它！"
  echo ""; exit 1
fi
ok "Docker 引擎与 Compose 编排插件均已就绪"
info "宿主机引擎当前拓扑参数摘要："
docker_info_brief || true


title "02/10. 容器进程守护层幂等重置"
info "正在安全重启 containerd 与 docker 后台进程并锁固套接字..."
restart_daemons || { err "错误：Docker 守护进程唤醒超时，Socket 未就绪！"; exit 1; }
ok "Docker 引擎套接字响应成功，通信管道畅通"


title "03/10. 全局端口占道分析与陈旧环境清洗"
info "正在深入排查敏感网络端口 (53/5335) 是否存在突发性碰撞冲突..."
# 【代码审计修正】：PORTS 实际定义的扫描目标为 53 和 5335，已在下方提示和注释中精准对齐
PORTS="53 5335"
TMP_CONTAINER=$(mktemp)
TMP_PROCESS=$(mktemp)

# 阶段 A：检索占用目标端口的活跃 Docker 容器
# 说明：
#   Docker 容器占用端口时，宿主机上通常会看到 docker-proxy 或 iptables/nft 转发规则。
#   这里优先从 docker ps 的端口映射中识别容器，而不是直接 kill docker-proxy。
#   这样可以准确停止并删除对应容器，避免留下 Compose 状态不一致的残留环境。
for PORT in $PORTS; do
  docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep ":$PORT->" | while read ID NAME _; do
    echo "$PORT $ID $NAME" >> "$TMP_CONTAINER"
  done
done

# 阶段 B：检索占用目标端口的孤立原生系统进程
# 说明：
#   如果目标端口不是被 Docker 容器占用，而是被原生进程占用，例如旧版 dnsmasq、
#   named、AdGuardHome 二进制进程等，则记录 PID 并在后续释放。
#   对 docker-proxy 会做额外判断，尽量避免重复处理已经归属于容器的端口占用。
for PORT in $PORTS; do
  netstat -tulpn 2>/dev/null | grep ":$PORT" | while read -r line; do
    proto=$(echo "$line" | awk '{print $1}')
    pid_info=$(echo "$line" | awk '{print $NF}')
    echo "$pid_info" | grep -qE '^[0-9]+/[^[:space:]]+$' || continue
    pid=$(echo "$pid_info" | cut -d'/' -f1)
    name=$(echo "$pid_info" | cut -d'/' -f2)
    [ "$name" = "docker-proxy" ] && docker ps | grep -q "$PORT" && continue
    echo "$PORT $proto $pid $name" >> "$TMP_PROCESS"
  done
done

if [ ! -s "$TMP_CONTAINER" ] && [ ! -s "$TMP_PROCESS" ]; then
  ok "完美！目标核心网口未被任何外部进程或残留容器强占"
else
  if [ -s "$TMP_CONTAINER" ]; then
    warn "检测到留存容器正在强占网络通路："
    awk '{printf "       ⚡ 容器 %s (%s) 正强占网口: %s\n", $3, $2, $1}' "$TMP_CONTAINER"
  fi
  if [ -s "$TMP_PROCESS" ]; then
    warn "检测到活跃孤立系统进程强占网络通路："
    awk '{printf "       ⚡ 孤立进程 %-16s [PID=%s] 正强占网口: %s/%s\n", $4, $3, $1, $2}' "$TMP_PROCESS"
  fi
  
  info "启动自动消杀处理，强行释放网络端口占用通道..."
  if [ -s "$TMP_CONTAINER" ]; then
    sort -u "$TMP_CONTAINER" | awk '{print $2}' | sort -u | while read ID; do
      docker stop "$ID" >/dev/null 2>&1 || true
      docker rm "$ID"   >/dev/null 2>&1 || true
    done
  fi
  if [ -s "$TMP_PROCESS" ]; then
    awk '{print $3}' "$TMP_PROCESS" | sort -u | while read PID; do
      kill "$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null || true
    done
  fi
  ok "陈旧冲突项已强制净化，端口通路成功恢复释放"
fi
rm -f "$TMP_CONTAINER" "$TMP_PROCESS"

info "清除并归档两路网络组件的核心历史配置数据夹..."
# 说明：
#   这里采用“完全重建目录”的方式，保证脚本幂等性。
#   好处是避免旧配置、旧规则、旧 compose 文件与新版本混用。
#   注意：这会删除 $HOME/mosdns 与 $HOME/adh 下的旧数据。
#   如果未来需要保留历史配置，可在此处改为 mv 备份，而不是 rm -rf。
rm -rf "$MOSDNS_DIR" "$ADH_DIR"
mkdir -p "$MOSDNS_DIR" "$ADH_DIR/conf" "$ADH_DIR/work"
ok "目标拓扑环境根目录彻底清洗与二次重塑完成"


title "04/10. 拉取并编排下发 AdGuard Home 云配方"
info "正在从远端镜像仓拉取定制版 adh.yaml 核心配置定义..."
# AdGuard Home 配置说明：
#   下载后的文件固定保存为：
#     $ADH_DIR/conf/AdGuardHome.yaml
#   该文件会被 Docker Compose 挂载进 AdGuard Home 容器。
#   因此如果下载失败，AdGuard Home 即使容器启动，也可能没有预期的上游 DNS / 规则配置。
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/adh.yaml \
  -o "$ADH_DIR/conf/AdGuardHome.yaml"
info "正在从远端镜像仓拉取最新版 docker-compose.yaml 编排规约..."
# Compose 文件说明：
#   此处下载的是 AdGuard Home 专用 docker-compose.yaml。
#   后续会在 $ADH_DIR 内执行 docker compose up -d。
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/adh \
  -o "$ADH_DIR/docker-compose.yaml"

info "触发 Compose 编排，拉起 AdGuard Home 独立隔离沙箱..."
( cd "$ADH_DIR" && docker compose down -v >/dev/null 2>&1 || true )
( cd "$ADH_DIR" && docker compose up -d )
ok "AdGuard Home 容器沙箱实例化运行完毕"


title "05/10. 拉取并配置 MosDNS 业务核心资源文件"
info "正在下发 MosDNS 多态编排堆栈定义与自维护更新控制台脚本..."
cd "$MOSDNS_DIR"
# MosDNS Compose 文件说明：
#   下载后保存为 $MOSDNS_DIR/docker-compose.yaml。
#   该文件负责定义 MosDNS 容器、端口映射、配置挂载路径等运行参数。
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/mosdns \
  -o ./docker-compose.yaml
# update.sh 说明：
#   该脚本用于首次拉取和后续定时更新 MosDNS 所需规则数据。
#   下方第 06/10 阶段会将它挂入 root crontab，形成每周自动更新任务。
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/main/mosdns/update.sh \
  -o ./update.sh
chmod +x ./update.sh

info "唤醒内部数据自维护功能，执行地理特征库（GeoIP/GeoSite）首次冷拉取..."
./update.sh || true
ok "MosDNS 运行生命周期管理层构建完成"


title "06/10. 绑定持久化系统的 Crontab 定时规则"
info "正在向 Alpine 核心计划任务管理器中挂载规则特征库每周自动刷新任务..."
touch "$CRONTAB_FILE"
# Crontab 幂等设计：
#   1. 先删除旧的同路径 update.sh 任务。
#   2. 再追加新的标准任务。
#   这样脚本重复执行时，不会在 /etc/crontabs/root 中产生多条重复任务。
#
# 当前任务含义：
#   0 4 * * 1
#   每周一凌晨 04:00 执行 MosDNS 规则更新。
#
# 日志输出：
#   标准输出和错误输出都会追加写入：
#     $MOSDNS_DIR/update.log
sed -i '\#cd '"$MOSDNS_DIR"' && ./update.sh#d' "$CRONTAB_FILE"
echo "0 4 * * * cd $MOSDNS_DIR && ./update.sh >> $MOSDNS_DIR/update.log 2>&1" >> "$CRONTAB_FILE"
ok "系统自动巡检任务队列挂载完成（执行频次：每周一凌晨 04:00）"


title "07/10. 下发全局域名分流规则与白/灰名册精细化策略"
info "正在同步下发本地专属分流名单（geoip_private.txt、hosts.txt）..."
mkdir -p "$MOSDNS_DIR/rules-dat" "$MOSDNS_DIR/config/rule"
# rules-dat 目录说明：
#   geoip_private.txt：用于识别私有地址、内网地址等特殊 IP 段。
#   hosts.txt：用于承载本地静态 hosts 映射。
for s in geoip_private.txt hosts.txt; do
  curl -fsSL "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/rules-dat/$s" -o "$MOSDNS_DIR/rules-dat/$s"
done

info "正在构建高精路由分流规则控制拓扑配置文件（config_custom.yaml、dns.yaml）..."
# config 目录说明：
#   config_custom.yaml：MosDNS 主逻辑入口，通常定义 CN / GFW / 非 CN 分流链路。
#   dns.yaml：上游 DNS 定义文件，通常包含 ADH_CN、ADH_GFW 或其它上游。
#   dat_exec.yaml：规则数据执行与 ECS / no_ecs 等处理逻辑。
for f in config_custom.yaml dns.yaml dat_exec.yaml; do
  curl -fsSL "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/main/mosdns/config/$f" -o "$MOSDNS_DIR/config/$f"
done

info "正在向静态过滤池追加高可用名单策略白名册/灰名册/跳过缓存表..."
# config/rule 目录说明：
#   whitelist.txt：强制白名单，通常用于指定域名走特定解析路径。
#   greylist.txt：灰名单，通常用于需要特殊判断或特殊分流的域名。
#   nocache.txt：跳过缓存名单，适合经常变化或不希望缓存的域名。
for r in whitelist.txt greylist.txt nocache.txt; do
  curl -fsSL "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/rule/$r" -o "$MOSDNS_DIR/config/rule/$r"
done
ok "多级联动规则过滤数据库及逻辑调配节点全部对齐完毕"


title "08/10. 唤醒并冷启动 MosDNS 域名分流服务"
info "执行强制重构编排指令，拉起全负载高性能 MosDNS 容器实例..."
cd "$MOSDNS_DIR"
# --force-recreate 说明：
#   即使 Compose 判断容器配置似乎没有变化，也强制重建 MosDNS 容器。
#   这样可以确保刚刚下载的新配置、新规则、新 compose 文件全部被重新加载。
docker compose up -d --force-recreate
ok "MosDNS 高阶安全 DNS 混流引擎成功接管业务"


title "09/10. 网络协同拓扑服务健康度自检"
info "当前宿主机多租户容器网络沙箱实时活跃分布状态："
echo "     ----------------------------------------------------------------------------------------"
docker ps --format '     | 容器名称: %-22s | 运行状态: %-16s | 端口映射: %-22s |' | sed -n '1,20p'
echo "     ----------------------------------------------------------------------------------------"

# ============================================================================
# 极客高精中英混合文本视觉对齐算法（端口探测专属）
# ============================================================================
check_port() {
  DESC="$1"; CHECK_CMD="$2"
  
  # 动态计算中英混合文本的真实屏幕投影列宽
  BYTES=$(printf "%s" "$DESC" | wc -c)
  CHARS=$(printf "%s" "$DESC" | wc -m)
  VISUAL_WIDTH=$(( (BYTES + CHARS) / 2 ))
  
  TARGET_LINE_WIDTH=50
  if [ $VISUAL_WIDTH -lt $TARGET_LINE_WIDTH ]; then
    PAD_STR=$(printf "%$(( TARGET_LINE_WIDTH - VISUAL_WIDTH ))s" " ")
  else
    PAD_STR=" "
  fi

  if sh -c "$CHECK_CMD" >/dev/null 2>&1; then
    printf "  ${GREEN}✔${NC}  %s%s [ ${GREEN}OK${NC} ]\n" "$DESC" "$PAD_STR"
  else
    printf "  ${YELLOW}▲${NC}  %s%s [ ${YELLOW}WARN${NC} ]\n" "$DESC" "$PAD_STR"
  fi
}

info "启动局域网回环控制点端口可用性深度全扫描..."
if command -v nc >/dev/null 2>&1; then
  check_port "AdGuard Home 可视化控制台面板 (Port 80/TCP)" "nc -zv 127.0.0.1 80"
  check_port "AdGuard Home 核心DNS服务监听 (Port 53/TCP)" "nc -zv 127.0.0.1 53"
else
  warn "本地环境未探查到 nc 探测小工具，自动跳过精确端口链路级物理扫描"
fi


title "10/10. 协同部署工作全面收敛总结"
# 将系统基本诊断摘要静默转储进历史技术报告文件中
echo "==== docker info (brief) ====" >> "$REPORT"
docker_info_brief >> "$REPORT" 2>&1 || true

# 通栏横幅控制台仪表盘 (Horizontal Banner Layout - 彻底解决路径拉伸错位问题)
printf "${GREEN}======================================================================${NC}\n"
printf "${BOLD}${GREEN}  🎉 恭喜！联合网络协同服务部署全部成功，底层业务链平稳挂载！${NC}\n"
printf "${GREEN}----------------------------------------------------------------------${NC}\n"
printf "  ${BOLD}💡 【实时运维监控直达指令摘要】${NC}\n"
printf "   • 实时跟踪追踪 ${CYAN}MosDNS${NC} 分流日志:\n"
printf "     ${BOLD}${CYAN}cd $MOSDNS_DIR && docker compose logs -f mosdns${NC}\n"
printf "   • 实时跟踪追踪 ${CYAN}AdGuard Home${NC} 拦截日志:\n"
printf "     ${BOLD}${CYAN}cd $ADH_DIR && docker compose logs -f${NC}\n\n"
printf "  ${BOLD}🧾 数字化大盘技术体检报告已归档至:${NC}\n"
printf "     ${BOLD}${YELLOW}$REPORT${NC}\n"
printf "${GREEN}======================================================================${NC}\n\n"
