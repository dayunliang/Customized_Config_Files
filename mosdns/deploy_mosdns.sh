#!/bin/sh
set -e  # 脚本遇到任何非零退出状态立即停止，防止后续步骤在错误状态下执行

# --------------------------------------------------------------------------
# 变量定义
# --------------------------------------------------------------------------
BASE_DIR="$HOME/mosdns"    # 定义 mosdns 工作目录，后续所有文件下载/操作都在此目录下进行

# --------------------------------------------------------------------------
# 1. 更新 APK 镜像源
# --------------------------------------------------------------------------
echo "[1/14] 更新 APK 镜像源…" 
# 将 /etc/apk/repositories 覆盖写为国内 USTC 镜像，加速包下载
cat >/etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF
apk update                  # 更新索引，确保后续安装能从新的源获取包
echo "  APK 源已更新。"

# --------------------------------------------------------------------------
# 2. 检查并安装 Docker
# --------------------------------------------------------------------------
echo "[2/14] 检查 Docker…" 
if ! command -v docker >/dev/null 2>&1; then
  # 如果 docker 命令不存在，就安装 Docker
  echo "  未检测到 Docker，正在安装…"
  apk add --no-cache docker   # 安装 docker 包
  echo "  Docker 安装完成。"
else
  echo "  Docker 已安装，跳过。"
fi
echo "  Docker 版本："
docker version               # 显示当前 Docker 客户端/服务端版本，验证安装成功

# --------------------------------------------------------------------------
# 3. 启动 Docker daemon
# --------------------------------------------------------------------------
echo "[3/14] 启动 Docker daemon…"
rc-service docker start      # 使用 OpenRC 启动 Docker 服务守护进程
echo "  Docker daemon 已启动。"

# --------------------------------------------------------------------------
# 4. 设置 Docker 开机启动
# --------------------------------------------------------------------------
echo "[4/14] 检查 Docker 开机启动…"
# rc-update show 列出所有服务以及它们在哪个 runlevel，grep '^docker.*boot' 检查 boot 级别
if ! rc-update show | grep -q '^docker.*boot'; then
  rc-update add docker boot   # 把 docker 服务加入到系统启动时执行
  echo "  已将 Docker 添加到 boot 阶段。"
else
  echo "  Docker 已设置为开机启动。"
fi

# --------------------------------------------------------------------------
# 5. 配置 Docker Registry 镜像源
# --------------------------------------------------------------------------
echo "[5/14] 配置 Docker Registry 镜像源…"
mkdir -p /etc/docker            # 确保配置目录存在
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
service docker restart           # 重启 Docker 服务以加载新的镜像源配置
echo "  Docker 服务已重启。"

# --------------------------------------------------------------------------
# 6. 验证 Docker Registry 镜像源配置
# --------------------------------------------------------------------------
echo "[6/14] 验证 Docker 镜像源…"
docker info | grep 'Registry Mirrors'  # 查看当前生效的 registry mirrors 列表
echo "  如上显示已配置的镜像源。"

# --------------------------------------------------------------------------
# 7. 检查并安装 docker-compose 和 lsof
# --------------------------------------------------------------------------
echo "[7/14] 检查 docker-compose 与 lsof…"
# docker-compose 用于启动多容器，lsof 用于检查端口占用
if ! command -v docker-compose >/dev/null 2>&1; then
  echo "  未检测到 docker-compose，正在安装…"
  apk update
  apk add --no-cache docker-compose  # 安装 docker-compose
  echo "  docker-compose 安装完成。"
else
  echo "  docker-compose 已安装，跳过。"
fi
if ! command -v lsof >/dev/null 2>&1; then
  echo "  未检测到 lsof，正在安装…"
  apk add --no-cache lsof            # 安装 lsof 用于端口检查
  echo "  lsof 安装完成。"
else
  echo "  lsof 已安装，跳过。"
fi

# --------------------------------------------------------------------------
# 8. 清理旧容器与目录
# --------------------------------------------------------------------------
echo "[8/14] 清理旧容器与目录…"
cd ~                               # 切换到家目录，保证后续删除操作不在目标目录内部
# 如果存在名为 mosdns 的容器，强制删除它
if docker ps -a --format '{{.Names}}' | grep -xq mosdns; then
  docker rm -f mosdns
  echo "  已删除旧容器 mosdns"
fi
# 删除并重建 mosdns 工作目录
if [ -d "$BASE_DIR" ]; then
  rm -rf "$BASE_DIR"
  echo "  已删除目录 $BASE_DIR"
fi
mkdir -p "$BASE_DIR"
echo "  已创建目录 $BASE_DIR"

# --------------------------------------------------------------------------
# 9. 检查宿主机上是否有其他 DNS 服务占用 53 端口
# --------------------------------------------------------------------------
echo "[9/14] 检查宿主机上是否有其他 DNS 服务占用 53 端口…"
# 使用 lsof 检查 TCP 和 UDP 的 53 端口监听情况，忽略命令错误
occupiers="$(lsof -nP -iTCP:53 -sTCP:LISTEN -Fpcn || true; lsof -nP -iUDP:53 -Fpcn || true)"
if [ -n "$occupiers" ]; then
  echo "  以下进程占用了端口 53："
  # 解析 lsof 输出：p 开头为 PID，c 开头为命令名
  echo "$occupiers" | awk '
    /^p/ { pid = substr($0,2) }
    /^c/ { cmd = substr($0,2); print "    PID=" pid ", 程序=" cmd }
  '
  # 提示用户是否终止这些进程
  read -p "是否停止上述进程并继续？[y/N]: " yn
  case "$yn" in
    [Yy]* )
      # 仅终止那些 PID
      echo "$occupiers" | awk '/^p/ {print substr($0,2)}' | xargs -r kill \
        && echo "    已终止占用端口 53 的进程。"
      ;;
    * )
      echo "  已取消部署，请先停止这些服务后重试。" >&2
      exit 1
      ;;
  esac
else
  echo "  宿主机上未检测到其它进程监听 53 端口。"
fi

# --------------------------------------------------------------------------
# 10. 下载 docker-compose.yaml 与 update.sh
# --------------------------------------------------------------------------
echo "[10/14] 下载 docker-compose.yaml 与 update.sh…"
cd "$BASE_DIR"
# 从 GitHub 仓库下载最新的 compose 文件和更新脚本
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose.yaml
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/update.sh
chmod +x update.sh    # 赋予 update.sh 可执行权限
echo "  下载完成。"

# --------------------------------------------------------------------------
# 11. 执行 update.sh 更新规则
# --------------------------------------------------------------------------
echo "[11/14] 执行 update.sh 更新规则…"
./update.sh           # 调用脚本拉取 geoip/geosite 等最新规则文件
echo "  update.sh 执行完毕。"

# --------------------------------------------------------------------------
# 12. 进入 rules-dat 并新增 geoip_private.txt
# --------------------------------------------------------------------------
echo "[12/14] 进入 rules-dat 并新增 geoip_private.txt…"
# 创建 rules-dat 目录，并在其中创建空文件 geoip_private.txt
mkdir -p "$BASE_DIR/rules-dat"
cd "$BASE_DIR/rules-dat"
: > geoip_private.txt  # “:” 是 no-op，占位符，用于重定向创建空文件

# --------------------------------------------------------------------------
# 13. 创建 config 目录并下载配置文件及 rule 子目录
# --------------------------------------------------------------------------
echo "[13/14] 创建 config 并下载配置文件…"
# config 用于存放 mosdns 主配置文件
mkdir -p "$BASE_DIR/config/rule"
cd "$BASE_DIR/config"
# 循环下载三份核心配置：主配置、dns.yaml、dat_exec.yaml
for f in config_custom.yaml dns.yaml dat_exec.yaml; do
  wget -q "https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/$f"
done
# 进入 rule 子目录，创建空的白/灰名单文件
cd rule
: > whitelist.txt
: > greylist.txt

# --------------------------------------------------------------------------
# 14. 启动 mosdns 容器
# --------------------------------------------------------------------------
echo "[14/14] 启动 mosdns 容器…"
cd "$BASE_DIR"
docker-compose up -d   # 后台启动容器并自动拉取镜像
echo "部署完成！使用 'docker-compose logs -f mosdns' 查看日志。"
