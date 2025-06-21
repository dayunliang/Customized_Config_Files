#!/bin/sh
# ----------------------------------------------------------------------------
# Script Name: deploy-mosdns.sh
# 作用：一键部署 MosDNS + 国内/国外 AdGuardHome 的容器服务
# 环境需求：Alpine Linux（OpenRC）+ Docker + 网络支持
# 功能目标：构建分流、防污染、高性能、本地可控的 DNS 体系
# 作者：Andy Da（由 ChatGPT 协助完成）
# 最后更新时间：2025-06-21
# ----------------------------------------------------------------------------

set -e  # 遇到任意错误立即退出脚本执行

# ======================== 目录变量定义 ========================
MOSDNS_DIR="$HOME/mosdns"        # MosDNS 配置主目录
ADH_CN_DIR="$HOME/AdH_CN"        # 国内 AdGuardHome 容器配置目录
ADH_GFW_DIR="$HOME/AdH_GFW"      # 国外 AdGuardHome 容器配置目录
CRONTAB_FILE="/etc/crontabs/root"  # Alpine 中 root 用户的定时任务文件

# ======================== 步骤 7：清理环境函数 ========================
cleanup_environment() {
  # 清理前检查端口占用（53/54/55）
  PORTS="53 54 55"
  TMP_CONTAINER=$(mktemp)
  TMP_PROCESS=$(mktemp)

  echo "[7/14] 清理旧容器并释放端口占用..."

  # 检查当前是否有容器监听目标端口
  for PORT in $PORTS; do
    docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep ":$PORT->" | while read ID NAME PORTMAP; do
      echo "$PORT $ID $NAME" >> "$TMP_CONTAINER"
    done
  done

  # 检查是否有系统进程占用端口（排除 docker-proxy）
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
    echo "✅ 没有发现任何需要释放的端口占用。"
  else
    echo "📝 以下对象将被释放："
    [ -s "$TMP_CONTAINER" ] && awk '{printf "  → 容器 %s (%s) 监听端口 %s\n", $3, $2, $1}' "$TMP_CONTAINER"
    [ -s "$TMP_PROCESS" ] && awk '{printf "  → [%s] 端口 %s - PID=%s - 类型=%s - 进程名=%s\n", $2, $1, $3, $2, $4}' "$TMP_PROCESS"

    echo ""
    if [ -t 0 ]; then
      echo -n "⚠️ 是否终止这些容器 / 进程？[y/N]: "
      read CONFIRM
    else
      echo "⚠️ 非交互模式下默认取消操作。"
      CONFIRM="n"
    fi

    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
      echo "❎ 已取消操作。"
      rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
      exit 0
    fi

    echo "🛠️ 正在执行释放操作..."

    # 停止并删除容器
    [ -s "$TMP_CONTAINER" ] && sort -u "$TMP_CONTAINER" | awk '{print $2}' | sort -u | while read ID; do
      echo "  🛑 停止容器 $ID ..."
      docker stop "$ID" > /dev/null 2>&1 && echo "     ✅ 已停止" || echo "     ❌ 停止失败"
      echo "  ❌ 删除容器 $ID ..."
      docker rm "$ID" > /dev/null 2>&1 && echo "     ✅ 已删除" || echo "     ❌ 删除失败"
    done

    # 终止系统进程（优先 TERM，失败再 KILL）
    [ -s "$TMP_PROCESS" ] && awk '{print $3}' "$TMP_PROCESS" | sort -u | while read PID; do
      echo "  🔪 终止进程 PID=$PID ..."
      kill "$PID" 2>/dev/null && echo "     ✅ 已终止 (TERM)" || {
        kill -9 "$PID" 2>/dev/null && echo "     ⚠️ 已强制终止 (KILL)" || echo "     ❌ 无法终止进程 PID=$PID"
      }
    done
  fi

  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"

  echo ""
  echo "🧹 清理配置目录..."
  rm -rf "$MOSDNS_DIR" "$ADH_CN_DIR" "$ADH_GFW_DIR"
  mkdir -p "$MOSDNS_DIR"
  echo "✅ 环境清理完成。"
}

# [1/14] 设置 APK 镜像源为中科大，仅在首次执行时覆盖
if ! grep -q ustc /etc/apk/repositories 2>/dev/null; then
  echo "[1/14] 设置 APK 镜像源为中科大..."
  cat >/etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
  apk update
else
  echo "[1/14] APK 镜像源已设置，跳过。"
fi

# [2/14] 安装 VMware 工具包，支持宿主硬件识别
apk add --no-cache open-vm-tools
rc-update add open-vm-tools default
rc-service open-vm-tools start

# [3/14] 安装编辑器 + 中文本地化支持，避免乱码
apk add --no-cache vim musl-locales musl-locales-lang less
cat << 'EOF' >/etc/profile.d/locale.sh
export LANG=zh_CN.UTF-8
export LC_CTYPE=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
EOF
chmod +x /etc/profile.d/locale.sh
. /etc/profile.d/locale.sh
cat << 'EOF' >/etc/vim/vimrc
set encoding=utf-8
set termencoding=utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,default,latin1
EOF

# [4/14] 安装并启动 Docker 容器服务
apk add --no-cache docker
rc-update add docker boot
rc-service docker start

# [5/14] 配置国内加速的 Docker 镜像源，提高拉取效率
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://mirror.baidubce.com",
    "https://docker.nju.edu.cn",
    "https://docker.mirrors.sjtug.sjtu.edu.cn",
    "https://mirror.iscas.ac.cn"
  ]
}
EOF
service docker restart

# [6/14] 安装 Docker Compose 工具和基础网络工具
apk add --no-cache docker-compose net-tools curl

# [7/14] 清理旧环境并释放端口占用
cleanup_environment

# [8/14] 拉取并启动 AdGuardHome（国内）容器
mkdir -p "$ADH_CN_DIR/conf" "$ADH_CN_DIR/work"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/AdH_CN.yaml -o "$ADH_CN_DIR/conf/AdGuardHome.yaml"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/AdH_CN -o "$ADH_CN_DIR/docker-compose.yaml"
cd "$ADH_CN_DIR"
docker-compose up -d --force-recreate

# [9/14] 拉取并启动 AdGuardHome（国外）容器
mkdir -p "$ADH_GFW_DIR/conf" "$ADH_GFW_DIR/work"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/AdH_GFW.yaml -o "$ADH_GFW_DIR/conf/AdGuardHome.yaml"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/AdH_GFW -o "$ADH_GFW_DIR/docker-compose.yaml"
cd "$ADH_GFW_DIR"
docker-compose up -d --force-recreate

# [10/14] 拉取 MosDNS 的 docker-compose 和自动更新脚本
cd "$MOSDNS_DIR"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/mosdns -o ./docker-compose.yaml
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/main/mosdns/update.sh -o ./update.sh
chmod +x update.sh
./update.sh  # 初始执行一次，拉取规则等

# [11/14] 添加 cron 计划任务，每周一凌晨 4 点自动更新
mkdir -p /etc/periodic/weekly
sed -i '\#cd '"$MOSDNS_DIR"' && ./update.sh#d' "$CRONTAB_FILE"
echo "0 4 * * 1 cd $MOSDNS_DIR && ./update.sh >> $MOSDNS_DIR/update.log 2>&1" >> "$CRONTAB_FILE"

# [12/14] 创建空白规则文件并下载主要配置（国内/国际分流规则）
mkdir -p "$MOSDNS_DIR/rules-dat"
: > "$MOSDNS_DIR/rules-dat/geoip_private.txt"
mkdir -p "$MOSDNS_DIR/config/rule"
cd "$MOSDNS_DIR/config"
for f in config_custom.yaml dns.yaml dat_exec.yaml; do
  curl -fsSL "https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/main/mosdns/config/$f" -o "$f"
done
cd rule
: > whitelist.txt
: > greylist.txt

# [13/14] 启动 MosDNS 主服务容器
cd "$MOSDNS_DIR"
docker-compose up -d --force-recreate

# [14/14] 显示部署完成提示信息和正在运行的容器
echo "✅ 所有服务部署完成"
echo "📌 正在运行的容器："
docker ps
echo "📌 查看日志：docker-compose logs -f mosdns"
