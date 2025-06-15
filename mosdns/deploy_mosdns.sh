#!/bin/sh
set -e  # 脚本遇到任何错误立即退出，防止出现半成品状态

# --------------------------------------------------------------------------
# 变量定义
# --------------------------------------------------------------------------
BASE_DIR="$HOME/mosdns"    # 定义 mosdns 的工作目录

# --------------------------------------------------------------------------
# 1. 更新 APK 镜像源
# --------------------------------------------------------------------------
echo "[1/14] 更新 APK 镜像源…"
# 写入国内 USTC 源，加速包下载
cat >/etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
apk update                  # 刷新包索引
echo "  APK 源已更新。"

# --------------------------------------------------------------------------
# 2. 检查并安装 Docker
# --------------------------------------------------------------------------
echo "[2/14] 检查 Docker…"
# 如果 docker 命令不存在，则安装 docker 包
if ! command -v docker >/dev/null 2>&1; then
  echo "  未检测到 Docker，正在安装…"
  apk add --no-cache docker
  echo "  Docker 安装完成。"
else
  echo "  Docker 已安装，跳过安装。"
fi

# --------------------------------------------------------------------------
# 3. 启动 Docker 守护进程
# --------------------------------------------------------------------------
echo "[3/14] 启动 Docker daemon…"
# OpenRC 环境下启动 docker 服务
rc-service docker start
echo "  Docker daemon 已启动。"

# --------------------------------------------------------------------------
# 4. 将 Docker 设置为开机自启动
# --------------------------------------------------------------------------
echo "[4/14] 检查 Docker 开机启动配置…"
# 查看是否已经加入 boot runlevel
if ! rc-update show | grep -q '^docker.*boot'; then
  rc-update add docker boot
  echo "  已将 Docker 添加到开机启动。"
else
  echo "  Docker 已配置为开机启动。"
fi

# --------------------------------------------------------------------------
# 5. 配置 Docker Registry 镜像加速器
# --------------------------------------------------------------------------
echo "[5/14] 配置 Docker Registry 镜像源…"
# 创建配置目录并写入加速镜像列表
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
service docker restart       # 重启 docker 服务，使配置生效
echo "  Docker 服务已重启。"

# --------------------------------------------------------------------------
# 6. 验证 Docker 镜像源是否生效
# --------------------------------------------------------------------------
echo "[6/14] 验证 Docker 镜像源配置…"
# 从 docker info 输出中筛选 Registry Mirrors 一行
docker info | grep 'Registry Mirrors'
echo "  如上所示，镜像源配置已生效。"

# --------------------------------------------------------------------------
# 7. 检查并安装 docker-compose 与 netstat
# --------------------------------------------------------------------------
echo "[7/14] 检查 docker-compose 与 netstat 工具…"
# docker-compose：启动多容器服务
if ! command -v docker-compose >/dev/null 2>&1; then
  apk update
  apk add --no-cache docker-compose
  echo "  docker-compose 安装完成。"
else
  echo "  docker-compose 已安装。"
fi
# netstat（来自 net-tools）：用于检查端口占用
if ! command -v netstat >/dev/null 2>&1; then
  apk add --no-cache net-tools
  echo "  netstat (net-tools) 安装完成。"
else
  echo "  netstat 已安装。"
fi

# --------------------------------------------------------------------------
# 8. 检查宿主机上是否有其他 DNS 服务占用 53 端口
# --------------------------------------------------------------------------
echo "[8/14] 检查宿主机上是否有其他 DNS 服务占用 53 端口…"
# 使用 netstat 列出所有监听或绑定的 53 端口行
occupiers=$(netstat -tulpn 2>/dev/null | grep -E ':(53)( |$|:)' || true)
if [ -z "$occupiers" ]; then
  echo "  未检测到任何服务监听或绑定 53 端口。"
else
  echo "  以下服务占用了 53 端口："
  # 格式化输出：协议、本地地址、对应的进程(程序名+PID)
  echo "$occupiers" | awk '{ printf "    协议=%-4s 本地=%-22s 程序=%s\n", $1, $4, $7 }'
  # 询问是否需要终止这些服务
  read -p "是否停止上述服务并继续？[y/N]: " yn
  case "$yn" in
    [Yy]* )
      # 提取程序列中“程序名,PID”，然后分割取 PID 再 kill
      echo "$occupiers" \
        | awk -F '[ /]+' '{print $7}' \
        | cut -d',' -f1 \
        | sort -u \
        | xargs -r kill \
        && echo "    已终止占用 53 端口的进程。"
      ;;
    * )
      echo "  已取消部署，请先释放端口后重试。" >&2
      exit 1
      ;;
  esac
fi

# --------------------------------------------------------------------------
# 9. 清理旧的 mosdns 容器及工作目录
# --------------------------------------------------------------------------
echo "[9/14] 清理旧容器与目录…"
cd ~
# 如果存在同名容器，则强制删除
if docker ps -a --format '{{.Names}}' | grep -xq mosdns; then
  docker rm -f mosdns
  echo "  已删除旧容器 mosdns"
fi
# 删除旧目录并重建
rm -rf "$BASE_DIR"
mkdir -p "$BASE_DIR"
echo "  已创建空目录 $BASE_DIR"

# --------------------------------------------------------------------------
# 10. 下载 docker-compose.yaml 与 update.sh
# --------------------------------------------------------------------------
echo "[10/14] 下载 docker-compose.yaml 与 update.sh…"
cd "$BASE_DIR"
# 从 GitHub 仓库获取最新文件
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose.yaml
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/update.sh
chmod +x update.sh
echo "  文件下载并赋予执行权限。"

# --------------------------------------------------------------------------
# 11. 执行 update.sh 更新规则
# --------------------------------------------------------------------------
echo "[11/14] 执行 update.sh 更新规则…"
# 更新 geoip、geosite 等规则文件
./update.sh
echo "  update.sh 执行完毕。"

# --------------------------------------------------------------------------
# 12. 在 rules-dat 目录下创建 geoip_private.txt
# --------------------------------------------------------------------------
echo "[12/14] 创建 rules-dat 并新增 geoip_private.txt…"
mkdir -p "$BASE_DIR/rules-dat"
cd "$BASE_DIR/rules-dat"
: > geoip_private.txt  # 使用重定向创建空文件
echo "  geoip_private.txt 已创建。"

# --------------------------------------------------------------------------
# 13. 创建 config 目录并下载三份配置与 rule 子目录下名单
# --------------------------------------------------------------------------
echo "[13/14] 创建 config 目录并下载主配置…"
mkdir -p "$BASE_DIR/config/rule"
cd "$BASE_DIR/config"
# 下载三份配置文件
for f in config_custom.yaml dns.yaml dat_exec.yaml; do
  wget -q "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/$f"
done
# 在 rule 子目录创建空白/灰名单
cd rule
: > whitelist.txt
: > greylist.txt
echo "  配置及名单文件已准备完毕。"

# --------------------------------------------------------------------------
# 14. 启动 mosdns 容器
# --------------------------------------------------------------------------
echo "[14/14] 启动 mosdns 容器…"
cd "$BASE_DIR"
docker-compose up -d   # 后台启动容器
echo "部署完成！"
echo "你可以运行 'docker-compose logs -f mosdns' 查看实时日志。"
