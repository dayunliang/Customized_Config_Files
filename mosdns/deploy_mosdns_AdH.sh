#!/bin/sh
set -e  # 遇到任何错误立即退出脚本执行

# 定义三个主要服务目录变量
MOSDNS_DIR="$HOME/mosdns"         # MosDNS 工作目录
ADH_CN_DIR="$HOME/AdH_CN"         # AdGuardHome 国内节点配置目录
ADH_GFW_DIR="$HOME/AdH_GFW"       # AdGuardHome GFW 节点配置目录
CRONTAB_FILE="/etc/crontabs/root" # Alpine 系统中 crontab 文件路径

# ==================================================================
# 函数：检查并释放占用端口 53/54/55 的容器或进程 + 清理旧配置目录
# ==================================================================
cleanup_environment() {
  PORTS="53 54 55"                        # 需要检查的端口列表
  TMP_CONTAINER=$(mktemp)                # 存储占用端口的容器临时文件
  TMP_PROCESS=$(mktemp)                  # 存储占用端口的非容器进程临时文件

  echo "[7/14] 清理旧容器并释放端口占用..."

  # 查找监听这些端口的 Docker 容器
  for PORT in $PORTS; do
    docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep ":$PORT->" | while read ID NAME PORTMAP; do
      echo "$PORT $ID $NAME" >> "$TMP_CONTAINER"
    done
  done

  # 查找监听这些端口的本地进程（排除 docker-proxy）
  for PORT in $PORTS; do
    netstat -tulpn 2>/dev/null | grep ":$PORT" | while read -r line; do
      proto=$(echo "$line" | awk '{print $1}')         # 协议类型（tcp/udp）
      pid_info=$(echo "$line" | awk '{print $NF}')     # 获取 PID/进程名
      echo "$pid_info" | grep -qE '^[0-9]+/[^[:space:]]+$' || continue
      pid=$(echo "$pid_info" | cut -d'/' -f1)
      name=$(echo "$pid_info" | cut -d'/' -f2)
      [ "$name" = "docker-proxy" ] && docker ps | grep -q "$PORT" && continue
      echo "$PORT $proto $pid $name" >> "$TMP_PROCESS"
    done
  done

  # 如果没有容器或进程占用端口，则直接退出
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

    echo ""
    echo "🛠️ 正在执行释放操作..."

    # 停止并删除占用端口的容器
    [ -s "$TMP_CONTAINER" ] && sort -u "$TMP_CONTAINER" | awk '{print $2}' | sort -u | while read ID; do
      echo "  🛑 停止容器 $ID ..."
      docker stop "$ID" > /dev/null 2>&1 && echo "     ✅ 已停止" || echo "     ❌ 停止失败"
      echo "  ❌ 删除容器 $ID ..."
      docker rm "$ID" > /dev/null 2>&1 && echo "     ✅ 已删除" || echo "     ❌ 删除失败"
    done

    # 终止占用端口的非容器进程
    [ -s "$TMP_PROCESS" ] && awk '{print $3}' "$TMP_PROCESS" | sort -u | while read PID; do
      echo "  🔪 终止进程 PID=$PID ..."
      kill "$PID" 2>/dev/null && echo "     ✅ 已终止 (TERM)" || {
        kill -9 "$PID" 2>/dev/null && echo "     ⚠️ 已强制终止 (KILL)" || echo "     ❌ 无法终止进程 PID=$PID"
      }
    done
  fi

  # 清理临时文件和配置目录
  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"

  echo ""
  echo "🧹 清理配置目录..."
  rm -rf "$MOSDNS_DIR" "$ADH_CN_DIR" "$ADH_GFW_DIR"
  mkdir -p "$MOSDNS_DIR"
  echo "✅ 环境清理完成。"
}

# --------------------------------------------------------------------------
# [1/14] 设置 APK 镜像源为中科大
# --------------------------------------------------------------------------
echo "[1/14] 设置 APK 镜像源为中科大..."
grep -q ustc /etc/apk/repositories 2>/dev/null || {
cat >/etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
apk update
}

# --------------------------------------------------------------------------
# [2/14] 安装 open-vm-tools
# --------------------------------------------------------------------------
echo "[2/14] 安装 open-vm-tools..."
apk add --no-cache open-vm-tools
rc-update add open-vm-tools default    # 设置开机启动
rc-service open-vm-tools start         # 启动服务

# --------------------------------------------------------------------------
# [3/14] 安装 vim 和中文支持
# --------------------------------------------------------------------------
echo "[3/14] 安装 vim 和中文支持..."
apk add --no-cache vim musl-locales musl-locales-lang less

# 设置中文环境变量
cat << 'EOF' >/etc/profile.d/locale.sh
export LANG=zh_CN.UTF-8
export LC_CTYPE=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
EOF
chmod +x /etc/profile.d/locale.sh
. /etc/profile.d/locale.sh

# 设置 Vim 默认编码
cat << 'EOF' >/etc/vim/vimrc
set encoding=utf-8
set termencoding=utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,default,latin1
EOF

# --------------------------------------------------------------------------
# [4/14] 安装并启动 Docker
# --------------------------------------------------------------------------
echo "[4/14] 安装并启动 Docker..."
apk add --no-cache docker
rc-update add docker boot             # 设置为开机自启
rc-service docker start               # 启动 Docker 服务

# --------------------------------------------------------------------------
# [5/14] 设置 Docker 镜像加速器
# --------------------------------------------------------------------------
echo "[5/14] 配置 Docker 镜像加速..."
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
service docker restart  # 应用新镜像加速配置

# --------------------------------------------------------------------------
# [6/14] 安装 docker-compose 和 net-tools 工具
# --------------------------------------------------------------------------
echo "[6/14] 安装 docker-compose 和 net-tools..."
apk add --no-cache docker-compose net-tools curl

# --------------------------------------------------------------------------
# [7/14] 执行环境清理函数
# --------------------------------------------------------------------------
cleanup_environment

# --------------------------------------------------------------------------
# [8/14] 部署 AdGuardHome 国内实例
# --------------------------------------------------------------------------
echo "[8/14] 部署 AdH_CN..."
mkdir -p "$ADH_CN_DIR/conf" "$ADH_CN_DIR/work"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/AdH_CN.yaml -o "$ADH_CN_DIR/conf/AdGuardHome.yaml"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/AdH_CN -o "$ADH_CN_DIR/docker-compose.yaml"
cd "$ADH_CN_DIR"
docker-compose up -d --force-recreate   # 强制重新创建并启动容器

# --------------------------------------------------------------------------
# [9/14] 部署 AdGuardHome GFW 实例
# --------------------------------------------------------------------------
echo "[9/14] 部署 AdH_GFW..."
mkdir -p "$ADH_GFW_DIR/conf" "$ADH_GFW_DIR/work"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/conf/AdH_GFW.yaml -o "$ADH_GFW_DIR/conf/AdGuardHome.yaml"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/AdH_GFW -o "$ADH_GFW_DIR/docker-compose.yaml"
cd "$ADH_GFW_DIR"
docker-compose up -d --force-recreate

# --------------------------------------------------------------------------
# [10/14] 下载 MosDNS 的 docker-compose 与 update.sh
# --------------------------------------------------------------------------
echo "[10/14] 下载 MosDNS 配置及 update.sh..."
cd "$MOSDNS_DIR"
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose/mosdns -o ./docker-compose.yaml
curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/main/mosdns/update.sh -o ./update.sh
chmod +x update.sh
./update.sh   # 初次执行更新脚本

# --------------------------------------------------------------------------
# [11/14] 设置 cron 每周一凌晨 4 点自动更新
# --------------------------------------------------------------------------
echo "[11/14] 设置 cron 自动更新..."
touch "$CRONTAB_FILE"
sed -i '\#cd '"$MOSDNS_DIR"' && ./update.sh#d' "$CRONTAB_FILE"
echo "0 4 * * 1 cd $MOSDNS_DIR && ./update.sh >> $MOSDNS_DIR/update.log 2>&1" >> "$CRONTAB_FILE"

# --------------------------------------------------------------------------
# [12/14] 下载规则和空白名单文件
# --------------------------------------------------------------------------
echo "[12/14] 下载规则和空白名单..."
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

# --------------------------------------------------------------------------
# [13/14] 启动 MosDNS 服务容器
# --------------------------------------------------------------------------
echo "[13/14] 启动 MosDNS..."
cd "$MOSDNS_DIR"
docker-compose up -d --force-recreate

# --------------------------------------------------------------------------
# [14/14] 提示所有服务部署完成
# --------------------------------------------------------------------------
echo "✅ 所有服务部署完成"
echo "📌 正在运行的容器："
docker ps
echo "📌 查看日志：docker-compose logs -f mosdns"
