#!/bin/sh
# ============================================================================
# 脚本名称：docker_alpine.sh
# 功能：在 Alpine Linux 上一键部署 Docker、Docker Compose、常用工具
# 特点：幂等性、安全性、可重复执行，自动检测是否已安装、配置项是否存在
# 作者：https://github.com/dayunliang
# 日期：2025-06-29
# ============================================================================

# 遇到任何命令出错立即终止脚本，避免出现未完成或错误的安装状态
set -e

# ----------------------------------------------------------------------------
# 0. 检查当前是否为 root 用户，因为安装系统组件需要 root 权限
# ----------------------------------------------------------------------------
echo "🔧 检查是否为 root 用户..."
if [ "$(id -u)" != "0" ]; then
  echo "❌ 请使用 root 用户执行本脚本。"
  exit 1
fi

# ----------------------------------------------------------------------------
# 1. 更换 Alpine Linux 的 apk 包管理镜像源为 USTC（中国科技大学），加速下载
# ----------------------------------------------------------------------------
echo "🔧 1. 设置 APK 镜像源为 USTC..."
tee /etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
# 使用 tee + EOF 重定向覆盖原始源列表内容

# ----------------------------------------------------------------------------
# 2. 更新软件包索引，获取最新的可用包列表
# ----------------------------------------------------------------------------
echo "📦 2. 更新软件包索引..."
apk update

# ----------------------------------------------------------------------------
# 3. 安装 docker、openrc（系统服务管理器）和 curl 工具
# 检查 docker 是否已安装，若未安装则执行安装
# ----------------------------------------------------------------------------
echo "📥 3. 安装 Docker 与 OpenRC..."
if apk info -e docker > /dev/null 2>&1; then
  echo "✅ docker 已安装，跳过安装。"
else
  apk add --no-cache docker openrc curl
  # --no-cache 可避免下载缓存残留，加快脚本运行速度
fi

# ----------------------------------------------------------------------------
# 4. 添加 Docker 到开机启动列表（rc-update 是 Alpine 使用的 init 系统）
# ----------------------------------------------------------------------------
echo "🚀 4. 设置 Docker 为开机启动服务..."
if ! rc-update show | grep -q docker; then
  rc-update add docker boot
  echo "✅ 已添加 docker 到启动项。"
else
  echo "🔁 docker 已在启动项中，跳过。"
fi

# ----------------------------------------------------------------------------
# 5. 配置 Docker 镜像加速器，提升 pull 镜像速度
# 若已有配置文件 /etc/docker/daemon.json 则备份后再写入新内容
# ----------------------------------------------------------------------------
echo "🔧 5. 配置 Docker 镜像加速器..."
mkdir -p /etc/docker
# 确保 /etc/docker 目录存在（idempotent）

if [ -f /etc/docker/daemon.json ]; then
  echo "📁 已存在 daemon.json，备份为 daemon.json.bak"
  cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
fi

# 写入国内常用 Docker 镜像加速器列表
tee /etc/docker/daemon.json <<-'EOF'
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

# ----------------------------------------------------------------------------
# 6. 启动 docker 服务，并重新加载配置（restart 或首次启动）
# ----------------------------------------------------------------------------
echo "📡 6. 启动并重启 Docker 服务..."
service docker restart || service docker start
# 若 restart 失败（服务未启动）则改为启动服务

# ----------------------------------------------------------------------------
# 7. 安装 docker-compose（二进制方式），若未安装则从 GitHub 下载最新版
# ----------------------------------------------------------------------------
echo "🔧 7. 安装 Docker Compose..."
if [ -f /usr/local/bin/docker-compose ]; then
  echo "✅ docker-compose 已存在，跳过安装。"
else
  # 获取 docker/compose 的 GitHub 最新版本号
  DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f4)

  # 下载指定版本的二进制文件
  curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose

  # 赋予执行权限
  chmod +x /usr/local/bin/docker-compose
  echo "✅ 安装完成：docker-compose ${DOCKER_COMPOSE_VERSION}"
fi

# ----------------------------------------------------------------------------
# 8. 安装常用系统工具（bash、curl、vim、htop、ca-certificates）
# 使用 apk info -e 判断是否已安装
# ----------------------------------------------------------------------------
echo "🧰 8. 安装常用工具（bash, curl, vim, htop, ca-certificates）..."

# 定义常用工具列表
TOOLS="bash curl vim htop ca-certificates"

# 遍历并安装每个工具（若未安装）
for pkg in $TOOLS; do
  if apk info -e "$pkg" > /dev/null 2>&1; then
    echo "✅ 已安装：$pkg"
  else
    echo "📦 正在安装：$pkg ..."
    apk add --no-cache "$pkg"
    echo "📥 安装完成：$pkg"
  fi
done

# ----------------------------------------------------------------------------
# 9. 验证安装结果，并展示镜像加速器设置情况
# ----------------------------------------------------------------------------
echo "🔍 9. 验证 Docker 和 Compose 安装结果..."
docker version
docker-compose version

echo "------ 当前启用的镜像加速器列表 ------"
docker info | grep -A20 "Registry Mirrors"

# ----------------------------------------------------------------------------
# 最后提示用户可以执行 docker 测试命令
# ----------------------------------------------------------------------------
echo "🎉 Docker + Compose + 常用工具环境部署完成！"
echo "📝 建议运行：docker run hello-world 进行测试。"
