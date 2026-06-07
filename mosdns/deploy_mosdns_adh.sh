#!/bin/sh
###############################################################################
# MosDNS + ADH 一键部署（依赖：已用 docker_alpine.sh 配好 Docker/Compose/crun）
# 适用：Alpine Linux，Docker 29+/containerd 2.x，默认使用 docker compose v2
###############################################################################
set -e

# ===== 基本变量 =====
MOSDNS_DIR="${HOME}/mosdns"
ADH_CN_DIR="${HOME}/adh_cn"
ADH_GFW_DIR="${HOME}/adh_gfw"
CRONTAB_FILE="/etc/crontabs/root"
REPORT="/root/mosdns_adh_deploy_$(date +%Y%m%d_%H%M%S).log"

# ===== 彩色输出 =====
G='\033[32m'; R='\033[31m'; Y='\033[33m'; B='\033[34m'; N='\033[0m'
ok(){   printf "${G}✔${N} %s\n" "$*"; }
warn(){ printf "${Y}▲${N} %s\n" "$*"; }
err(){  printf "${R}✘${N} %s\n" "$*"; }
info(){ printf "${B}i${N} %s\n" "$*"; }

# ===== 小工具函数 =====
wait_sock() { # 等待 docker.sock 最多 N 秒
  local N="${1:-20}" # 【已修复】使用 local 关键字，避免污染全局变量 N
  for _ in $(seq 1 "$N"); do
    [ -S /var/run/docker.sock ] && return 0
    sleep 1
  done
  return 1
}
restart_daemons() {
  rc-service docker stop  >/dev/null 2>&1 || true
  rc-service containerd stop >/dev/null 2>&1 || true
  rm -rf /run/containerd/io.containerd.runtime.v2.task/moby/* >/dev/null 2>&1 || true
  rc-service containerd start >/dev/null 2>&1 || true
  rc-service docker start >/dev/null 2>&1 || true
  wait_sock 25
}
docker_info_brief() {
  docker info 2>/dev/null | awk '
    /Server Version|Default Runtime|Runtimes|Storage Driver|Backing Filesystem|Cgroup Version/ {print}
  '
}

# ===== [1/14] APK 源 =====
echo "[1/14] 设置 APK 镜像源为中科大..."
if ! grep -q ustc /etc/apk/repositories 2>/dev/null; then
cat >/etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
apk update
fi
ok "APK 源已就绪"

# ===== [2/14] 基础包 =====
echo "[2/14] 安装基础包..."
apk add --no-cache open-vm-tools jq curl vim musl-locales musl-locales-lang less \
  net-tools iptables ip6tables c-ares nftables >/dev/null 2>&1 || true
rc-update add open-vm-tools default >/dev/null 2>&1 || true
rc-service open-vm-tools start >/dev/null 2>&1 || true
ok "基础包安装完成"

# ===== [3/14] 本地化（可选）=====
echo "[3/14] 配置中文环境与 Vim..."
cat >/etc/profile.d/locale.sh <<'EOF'
export LANG=zh_CN.UTF-8
export LC_CTYPE=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
EOF
chmod +x /etc/profile.d/locale.sh
. /etc/profile.d/locale.sh
cat >/etc/vim/vimrc <<'EOF'
set encoding=utf-8
set termencoding=utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,default,latin1
EOF
ok "中文环境与 Vim 已配置"

# ===== [4/14] Docker/Containerd/Compose（只做最小校验与提示）=====
echo "[4/14] 校验 Docker 与 Compose..."
if ! command -v docker >/dev/null 2>&1; then err "未检测到 docker，请先运行 docker_alpine.sh"; exit 1; fi
if ! docker compose version >/dev/null 2>&1; then err "未检测到 docker compose v2，请在 docker_alpine.sh 中启用"; exit 1; fi
ok "Docker 与 Compose 就绪"
info "Docker 信息（简要）："
docker_info_brief || true

# ===== [5/14] 重启守护进程并等待 sock（幂等保障）=====
echo "[5/14] 重启 containerd / docker..."
restart_daemons || { err "dockerd 未就绪"; exit 1; }
ok "dockerd socket 就绪"

# ===== [6/14] 清理环境（端口/容器/进程 + 目录）=====
echo "[6/14] 清理旧容器并释放端口（53/54/55）..."
PORTS="53 54 55"
TMP_CONTAINER=$(mktemp); TMP_PROCESS=$(mktemp)

for PORT in $PORTS; do
  docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep ":$PORT->" | while read ID NAME _; do
    echo "$PORT $ID $NAME" >> "$TMP_CONTAINER"
  done
done

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
  ok "无端口占用"
else
  [ -s "$TMP_CONTAINER" ] && awk '{printf "  → 容器 %s (%s) 监听 %s\n", $3, $2, $1}' "$TMP_CONTAINER"
  [ -s "$TMP_PROCESS" ] && awk '{printf "  → 进程 %-16s PID=%s 占用 %s/%s\n", $4, $3, $1, $2}' "$TMP_PROCESS"
  # 非交互默认直接处理
  [ -s "$TMP_CONTAINER" ] && sort -u "$TMP_CONTAINER" | awk '{print $2}' | sort -u | while read ID; do
    docker stop "$ID" >/dev/null 2>&1 || true
    docker rm "$ID"   >/dev/null 2>&1 || true
  done
  [ -s "$TMP_PROCESS" ] && awk '{print $3}' "$TMP_PROCESS" | sort -u | while read PID; do
    kill "$PID" 2>/dev/null || kill -9 "$PID" 2>/dev/null || true
  done
  ok "端口占用已释放"
fi
rm -f "$TMP_CONTAINER" "$TMP_PROCESS"

# 清理旧目录
echo "🧹 清理旧配置目录..."
rm -rf "$MOSDNS_DIR" "$ADH_CN_DIR" "$ADH_GFW_DIR"
mkdir -p "$MOSDNS_DIR" "$ADH_CN_DIR/conf" "$ADH_CN_DIR/work" "$ADH_GFW_DIR/conf" "$ADH_GFW_DIR/work"
ok "环境清理完成"

# ===== [7/14] 部署 ADH_CN =====
echo "[7/14] 部署 adh_cn..."
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/adh_cn.yaml \
  -o "$ADH_CN_DIR/conf/AdGuardHome.yaml"
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/adh_cn \
  -o "$ADH_CN_DIR/docker-compose.yaml"
( cd "$ADH_CN_DIR" && docker compose down -v >/dev/null 2>&1 || true )
( cd "$ADH_CN_DIR" && docker compose up -d )
ok "adh_cn 已启动"

# ===== [8/14] 部署 ADH_GFW =====
echo "[8/14] 部署 adh_gfw..."
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/adh_gfw.yaml \
  -o "$ADH_GFW_DIR/conf/AdGuardHome.yaml"
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/adh_gfw \
  -o "$ADH_GFW_DIR/docker-compose.yaml"
( cd "$ADH_GFW_DIR" && docker compose down -v >/dev/null 2>&1 || true )
( cd "$ADH_GFW_DIR" && docker compose up -d )
ok "adh_gfw 已启动"

# ===== [9/14] MosDNS 资源 =====
echo "[9/14] 下载 MosDNS compose 与 update.sh..."
cd "$MOSDNS_DIR"
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/mosdns \
  -o ./docker-compose.yaml
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/main/mosdns/update.sh \
  -o ./update.sh
chmod +x ./update.sh
./update.sh || true
ok "MosDNS 资源已准备"

# ===== [10/14] cron 自动更新 =====
echo "[10/14] 设置 cron 自动更新..."
touch "$CRONTAB_FILE"
sed -i '\#cd '"$MOSDNS_DIR"' && ./update.sh#d' "$CRONTAB_FILE"
echo "0 4 * * * cd $MOSDNS_DIR && ./update.sh >> $MOSDNS_DIR/update.log 2>&1" >> "$CRONTAB_FILE"
ok "Cron 规则已更新"

# ===== [11/14] 规则与空白名单 =====
echo "[11/14] 下载规则与空白名单..."
mkdir -p "$MOSDNS_DIR/rules-dat" "$MOSDNS_DIR/config/rule"

# 1. 从远程下载 geoip_private 和 hosts 文件
for s in geoip_private.txt hosts.txt; do
  curl -fsSL "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/rules-dat/$s" -o "$MOSDNS_DIR/rules-dat/$s"
done

# 2. 下载核心 yaml 配置文件
for f in config_custom.yaml dns.yaml dat_exec.yaml; do
  curl -fsSL "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/main/mosdns/config/$f" -o "$MOSDNS_DIR/config/$f"
done

# 3. 从远程下载白名单和灰名单
for r in whitelist.txt greylist.txt; do
  curl -fsSL "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/rule/$r" -o "$MOSDNS_DIR/config/rule/$r"
done

ok "规则与白/灰名单已就绪"

# ===== [12/14] 启动 MosDNS =====
echo "[12/14] 启动 MosDNS..."
cd "$MOSDNS_DIR"
docker compose up -d --force-recreate
ok "MosDNS 已启动"

# ===== [13/14] 验证与端口探测 =====
echo "[13/14] 验证服务与端口..."
echo "—— docker ps ——"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | sed -n '1,20p'

# TCP 端口探测（按常用映射）
command -v nc >/dev/null 2>&1 && {
  nc -zv 127.0.0.1 81   >/dev/null 2>&1 && ok "ADH_CN UI 81 OK"     || warn "ADH_CN UI 81 未监听"
  nc -zv 127.0.0.1 3001 >/dev/null 2>&1 && ok "ADH_CN 向导 3001 OK" || warn "ADH_CN 向导 3001 未监听"
  nc -zv 127.0.0.1 54   >/dev/null 2>&1 && ok "ADH_CN DNS 54/TCP OK"|| warn "ADH_CN DNS 54/TCP 未监听"

  nc -zv 127.0.0.1 82   >/dev/null 2>&1 && ok "ADH_GFW UI 82 OK"     || warn "ADH_GFW UI 82 未监听（如你的 compose 没映射则忽略）"
  nc -zv 127.0.0.1 3002 >/dev/null 2>&1 && ok "ADH_GFW 向导 3002 OK" || warn "ADH_GFW 向导 3002 未监听（如你的 compose 没映射则忽略）"
  nc -zv 127.0.0.1 55   >/dev/null 2>&1 && ok "ADH_GFW DNS 55/TCP OK"|| warn "ADH_GFW DNS 55/TCP 未监听"
} || true

# ===== [14/14] 汇总 =====
echo "==== docker info (brief) ====" >> "$REPORT"
docker_info_brief >> "$REPORT" 2>&1 || true

echo "✅ 所有服务部署完成"
echo "📌 查看 MosDNS 日志：  cd $MOSDNS_DIR && docker compose logs -f mosdns"
echo "📌 查看 ADH_CN 日志：  cd $ADH_CN_DIR && docker compose logs -f"
echo "📌 查看 ADH_GFW 日志： cd $ADH_GFW_DIR && docker compose logs -f"
echo "🧾 报告：$REPORT"
