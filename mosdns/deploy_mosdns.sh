#!/bin/sh
set -e  # 遇到任何错误立即退出

BASE_DIR="$HOME/mosdns"    # mosdns 根目录
CRONTAB_FILE="/etc/crontabs/root"

# --------------------------------------------------------------------------
# 1. 更新 APK 镜像源
# --------------------------------------------------------------------------
echo "[1/14] 更新 APK 镜像源…"
cat >/etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
apk update
echo "  APK 源已更新。"

# --------------------------------------------------------------------------
# 2. 检查并安装 Docker
# --------------------------------------------------------------------------
echo "[2/14] 检查 Docker…"
if ! command -v docker >/dev/null 2>&1; then
  apk add --no-cache docker
  echo "  Docker 安装完成。"
else
  echo "  Docker 已安装。"
fi

# --------------------------------------------------------------------------
# 3. 启动 Docker daemon
# --------------------------------------------------------------------------
echo "[3/14] 启动 Docker daemon…"
rc-service docker start
echo "  Docker daemon 已启动。"

# --------------------------------------------------------------------------
# 4. 设置 Docker 开机启动
# --------------------------------------------------------------------------
echo "[4/14] 检查 Docker 开机启动…"
if ! rc-update show | grep -q '^docker.*boot'; then
  rc-update add docker boot
  echo "  已将 Docker 添加到开机启动。"
else
  echo "  Docker 已配置为开机启动。"
fi

# --------------------------------------------------------------------------
# 5. 配置 Docker Registry 镜像源
# --------------------------------------------------------------------------
echo "[5/14] 配置 Docker Registry 镜像源…"
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
echo "  Docker 服务已重启。"

# --------------------------------------------------------------------------
# 6. 验证 Registry 镜像源配置
# --------------------------------------------------------------------------
echo "[6/14] 验证 Docker 镜像源…"
docker info | grep 'Registry Mirrors'
echo "  镜像源配置生效。"

# --------------------------------------------------------------------------
# 7. 检查并安装 docker-compose 与 netstat
# --------------------------------------------------------------------------
echo "[7/14] 检查 docker-compose 与 netstat…"
if ! command -v docker-compose >/dev/null 2>&1; then
  apk update
  apk add --no-cache docker-compose
  echo "  docker-compose 安装完成。"
else
  echo "  docker-compose 已安装。"
fi
if ! command -v netstat >/dev/null 2>&1; then
  apk add --no-cache net-tools
  echo "  netstat (net-tools) 安装完成。"
else
  echo "  netstat 已安装。"
fi

# --------------------------------------------------------------------------
# 8. 检查宿主机上是否有其他 DNS 服务占用 53 端口
# --------------------------------------------------------------------------
echo "[8/14] 检查端口 53 占用…"
occupiers=$(netstat -tulpn 2>/dev/null | grep -E ':(53)( |$|:)' || true)
if [ -z "$occupiers" ]; then
  echo "  未检测到任何服务占用端口 53。"
else
  echo "  以下服务占用了 53 端口："
  echo "$occupiers" | awk '{printf "    协议=%-4s 本地地址=%-22s 进程=%s\n",$1,$4,$7}'
  read -p "是否终止上述进程并继续？[y/N]: " yn
  case "$yn" in
    [Yy]* )
      echo "$occupiers" \
        | awk -F '[ /]+' '{print $7}' \
        | cut -d',' -f1 \
        | sort -u \
        | xargs -r kill \
        && echo "    已终止占用端口 53 的进程。"
      ;;
    * ) exit 1 ;;
  esac
fi

# --------------------------------------------------------------------------
# 9. 清理旧容器与目录
# --------------------------------------------------------------------------
echo "[9/14] 清理旧容器与目录…"
cd ~
if docker ps -a --format '{{.Names}}' | grep -xq mosdns; then
  docker rm -f mosdns
  echo "  已删除旧容器 mosdns"
fi
rm -rf "$BASE_DIR"
mkdir -p "$BASE_DIR"
echo "  已创建空目录 $BASE_DIR"

# --------------------------------------------------------------------------
# 10. 下载 docker-compose.yaml 与 update.sh
# --------------------------------------------------------------------------
echo "[10/14] 下载配置文件…"
cd "$BASE_DIR"
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose.yaml
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/update.sh
chmod +x update.sh
echo "  配置文件下载完成。"

# --------------------------------------------------------------------------
# 11. 执行 update.sh 并配置定时任务
# --------------------------------------------------------------------------
echo "[11/14] 执行 update.sh 并配置每周一 04:00 定时任务…"
# 立即执行一次
./update.sh && echo "  update.sh 执行完毕。"

# 确保 crontab 文件存在
touch "$CRONTAB_FILE"
# 删除所有已有关于 update.sh 的行
sed -i '\#cd '"$BASE_DIR"' && \./update.sh#d' "$CRONTAB_FILE"
# 添加新任务到末尾
echo "0 4 * * 1 cd $BASE_DIR && ./update.sh >> $BASE_DIR/update.log 2>&1" \
  >> "$CRONTAB_FILE"
echo "  已更新 $CRONTAB_FILE。"

# --------------------------------------------------------------------------
# 12. 创建 rules-dat 并新增 geoip_private.txt
# --------------------------------------------------------------------------
echo "[12/14] 创建 rules-dat 并新增 geoip_private.txt…"
mkdir -p "$BASE_DIR/rules-dat" && cd "$BASE_DIR/rules-dat"
: > geoip_private.txt
echo "  geoip_private.txt 已创建。"

# --------------------------------------------------------------------------
# 13. 创建 config 目录并下载规则 & 名单
# --------------------------------------------------------------------------
echo "[13/14] 创建 config/ rule 并下载文件…"
mkdir -p "$BASE_DIR/config/rule" && cd "$BASE_DIR/config"
for f in config_custom.yaml dns.yaml dat_exec.yaml; do
  wget -q "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/$f"
done
cd rule
: > whitelist.txt ; : > greylist.txt
echo "  config & rule 文件准备完毕。"

# --------------------------------------------------------------------------
# 14. 启动 mosdns 容器
# --------------------------------------------------------------------------
echo "[14/14] 启动 mosdns…"
cd "$BASE_DIR"
docker-compose up -d
echo "部署完成！使用 'docker-compose logs -f mosdns' 查看日志。"
