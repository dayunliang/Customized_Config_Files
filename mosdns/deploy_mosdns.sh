#!/bin/sh
set -e  # 遇到任何错误立即退出，确保脚本不会在错误条件下继续运行

BASE_DIR="$HOME/mosdns"          # MosDNS 的部署目录（~/mosdns）
CRONTAB_FILE="/etc/crontabs/root"  # 系统计划任务的 root 用户 crontab 文件

# --------------------------------------------------------------------------
# 1. 更新 APK 镜像源为中科大镜像，加快包管理速度
# --------------------------------------------------------------------------
echo "[1/16] 更新 APK 镜像源…"
cat >/etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
apk update
echo "  APK 源已更新。"

# --------------------------------------------------------------------------
# 2. 安装 open-vm-tools，用于增强 VMware 中 Alpine 的支持（剪贴板、时间同步等）
# --------------------------------------------------------------------------
echo "[2/16] 安装 open-vm-tools（VMware 工具）…"
apk add --no-cache open-vm-tools

# 设置 open-vm-tools 为开机启动，并立即启动服务
rc-update add open-vm-tools default
rc-service open-vm-tools start
echo "  open-vm-tools 已安装并启动。"

# --------------------------------------------------------------------------
# 3. 安装 vim 编辑器及 musl 中文本地化支持，使终端支持中文显示
# --------------------------------------------------------------------------
echo "[3/16] 安装 vim 和 musl 本地化包，并配置中文支持…"
apk add --no-cache vim musl-locales musl-locales-lang less

# 写入系统环境变量配置，设置为中文 UTF-8 编码
cat << 'EOF' >/etc/profile.d/locale.sh
export LANG=zh_CN.UTF-8
export LC_CTYPE=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
EOF
chmod +x /etc/profile.d/locale.sh
. /etc/profile.d/locale.sh  # 立即生效

# 配置 vim 的默认编码为 UTF-8，避免中文乱码
cat << 'EOF' >/etc/vim/vimrc
set encoding=utf-8
set termencoding=utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,default,latin1
EOF

echo "  vim 安装完成，中文显示支持已配置。"

# --------------------------------------------------------------------------
# 4. 检查 Docker 是否已安装，未安装则自动安装
# --------------------------------------------------------------------------
echo "[4/16] 检查 Docker…"
if ! command -v docker >/dev/null 2>&1; then
  apk add --no-cache docker
  echo "  Docker 安装完成。"
else
  echo "  Docker 已安装。"
fi

# --------------------------------------------------------------------------
# 5. 启动 Docker 服务（daemon）
# --------------------------------------------------------------------------
echo "[5/16] 启动 Docker daemon…"
rc-service docker start
echo "  Docker daemon 已启动。"

# --------------------------------------------------------------------------
# 6. 设置 Docker 服务开机自启
# --------------------------------------------------------------------------
echo "[6/16] 检查 Docker 开机启动…"
if ! rc-update show | grep -q '^docker.*boot'; then
  rc-update add docker boot
  echo "  已将 Docker 添加到开机启动。"
else
  echo "  Docker 已配置为开机启动。"
fi

# --------------------------------------------------------------------------
# 7. 配置 Docker 的 Registry 镜像源，加快镜像拉取速度
# --------------------------------------------------------------------------
echo "[7/16] 配置 Docker Registry 镜像源…"
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
# 8. 验证 Docker 镜像源是否配置生效
# --------------------------------------------------------------------------
echo "[8/16] 验证 Docker 镜像源…"
docker info | grep 'Registry Mirrors'
echo "  镜像源配置生效。"

# --------------------------------------------------------------------------
# 9. 安装 docker-compose 和 netstat（net-tools）工具
# --------------------------------------------------------------------------
echo "[9/16] 检查 docker-compose 与 netstat…"
if ! command -v docker-compose >/dev/null 2>&1; then
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
# 10. 检查本机 53 端口是否已被占用，提示是否释放端口
# --------------------------------------------------------------------------
echo "[10/16] 检查端口 53 占用…"
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
# 11. 删除旧容器与旧目录，准备新环境
# --------------------------------------------------------------------------
echo "[11/16] 清理旧容器与目录…"
cd ~
if docker ps -a --format '{{.Names}}' | grep -xq mosdns; then
  docker rm -f mosdns
  echo "  已删除旧容器 mosdns"
fi
rm -rf "$BASE_DIR"
mkdir -p "$BASE_DIR"
echo "  已创建空目录 $BASE_DIR"

# --------------------------------------------------------------------------
# 12. 下载 docker-compose.yaml 与 update.sh 部署脚本
# --------------------------------------------------------------------------
echo "[12/16] 下载配置文件…"
cd "$BASE_DIR"
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose.yaml
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/update.sh
chmod +x update.sh
echo "  配置文件下载完成。"

# --------------------------------------------------------------------------
# 13. 执行一次 update.sh 并设置为每周一 04:00 自动运行
# --------------------------------------------------------------------------
echo "[13/16] 执行 update.sh 并配置每周一 04:00 定时任务…"
./update.sh && echo "  update.sh 执行完毕。"
touch "$CRONTAB_FILE"
sed -i '\#cd '"$BASE_DIR"' && \./update.sh#d' "$CRONTAB_FILE"
echo "0 4 * * 1 cd $BASE_DIR && ./update.sh >> $BASE_DIR/update.log 2>&1" >> "$CRONTAB_FILE"
echo "  已更新 $CRONTAB_FILE。"

# --------------------------------------------------------------------------
# 14. 创建 rules-dat 目录并生成 geoip_private.txt 空文件
# --------------------------------------------------------------------------
echo "[14/16] 创建 rules-dat 并新增 geoip_private.txt…"
mkdir -p "$BASE_DIR/rules-dat" && cd "$BASE_DIR/rules-dat"
: > geoip_private.txt
echo "  geoip_private.txt 已创建。"

# --------------------------------------------------------------------------
# 15. 创建 config 和 rule 目录，并下载 MosDNS 配置与名单文件
# --------------------------------------------------------------------------
echo "[15/16] 创建 config/ rule 并下载文件…"
mkdir -p "$BASE_DIR/config/rule" && cd "$BASE_DIR/config"
for f in config_custom.yaml dns.yaml dat_exec.yaml; do
  wget -q "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/$f"
done
cd rule
: > whitelist.txt ; : > greylist.txt
echo "  config & rule 文件准备完毕。"

# --------------------------------------------------------------------------
# 16. 使用 docker-compose 启动 MosDNS 服务
# --------------------------------------------------------------------------
echo "[16/16] 启动 mosdns…"
cd "$BASE_DIR"
docker-compose up -d
echo "部署完成！使用 'docker-compose logs -f mosdns' 查看日志。"
