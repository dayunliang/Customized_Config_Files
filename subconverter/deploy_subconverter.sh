#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 作用：一键部署 Subconverter + Subweb（Web 前端）到指定目录，并用 docker compose 启动
# 特点：
#   - 使用 set -euo pipefail，尽量让脚本在错误发生时立刻退出，避免“半成功半失败”
#   - 自动下载 docker-compose.yaml 与 subweb 的 config.js
#   - 预防一个高频坑：把 config.js 误创建成目录导致 volume 挂载失败
#   - 自动兼容 docker compose v2 与 docker-compose v1
#
# 用法示例：
#   ./deploy_subconverter.sh                 # 默认部署到 ./subconverter
#   ./deploy_subconverter.sh /opt/subconverter  # 部署到指定目录
# -----------------------------------------------------------------------------

# 使用 /usr/bin/env 查找 bash，增强跨发行版兼容性（不同系统 bash 路径可能不同）
#!/usr/bin/env bash

# set -euo pipefail 的含义：
#   -e：任何命令返回非 0 立即退出（避免后续继续执行造成更大破坏）
#   -u：引用未定义变量立即退出（避免变量拼错导致写错目录/误删文件）
#   -o pipefail：管道命令中任意一段失败都算失败（否则只看最后一段的返回值）
set -euo pipefail

# BASE_DIR：部署目录
#   ${1:-./subconverter} 表示：
#     - 如果传了第 1 个参数，用它作为目录
#     - 否则默认使用 ./subconverter（相对当前执行目录）
BASE_DIR="${1:-./subconverter}"

# docker-compose.yaml 的远程地址（你 GitHub 仓库里的固定文件）
# 注意：这里用 raw.githubusercontent.com，要求机器能直连 GitHub（或走代理/镜像）
COMPOSE_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/subconverter/docker-compose.yaml"

# Subweb 前端 config.js 的远程地址
# 这个文件会被下载到本地并通过 volume 挂载进容器，从而覆盖容器内默认配置
CONFIG_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/subconverter/subweb/usr/share/nginx/html/conf/config.js"

# 打印部署目录，便于用户确认脚本要写到哪里（也便于排查权限/路径问题）
echo "==> Deploy dir: ${BASE_DIR}"

# 检查 curl 是否存在：
#   - command -v 会返回命令路径；如果不存在则返回非 0
#   - >/dev/null 2>&1：丢弃输出（保持终端干净）
#   - || {...}：若失败则打印错误并退出
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found"; exit 1; }

# 检查 docker 是否存在
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }

# -----------------------------------------------------------------------------
# 选择 docker compose 命令：
#   - docker compose（v2）是新写法（作为 docker 子命令）
#   - docker-compose（v1）是旧写法（独立二进制）
# 你的脚本通过检测来决定用哪一个，避免用户机器只有其中一种时运行失败。
# -----------------------------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
  # 若 v2 可用，优先用 v2
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  # 否则尝试 v1
  DC="docker-compose"
else
  # 两个都没有就无法启动 compose 编排
  echo "ERROR: docker compose (v2) or docker-compose not found"
  exit 1
fi

# 提示开始创建目录
echo "==> Creating directories..."

# 创建 subweb/conf 目录：
#   -p：父目录不存在也一并创建；已存在则不报错
# 目录结构解释（典型场景）：
#   BASE_DIR/
#     docker-compose.yaml
#     subweb/
#       conf/
#         config.js   <- 这里将被挂载到容器 /usr/share/nginx/html/conf/config.js 或 conf/ 目录
mkdir -p "${BASE_DIR}/subweb/conf"

# -----------------------------------------------------------------------------
# 防踩坑：有些人在排查时可能误操作：
#   mkdir -p subweb/conf/config.js
# 结果把 config.js 变成了“目录”，后续 curl -o 写文件会失败，
# 或 docker volume 挂载时类型不匹配导致容器启动报错：
#   "not a directory" / "is a directory"
# 因此这里专门检测：
#   如果 config.js 是目录 => rm -rf 删除它
# -----------------------------------------------------------------------------
if [ -d "${BASE_DIR}/subweb/conf/config.js" ]; then
  echo "==> Found directory ${BASE_DIR}/subweb/conf/config.js (should be a file). Removing..."
  rm -rf "${BASE_DIR}/subweb/conf/config.js"
fi

# -----------------------------------------------------------------------------
# 下载 docker-compose.yaml
# curl 参数说明：
#   -f：HTTP 非 2xx 直接失败（比如 404），并返回非 0
#   -s：静默模式，不显示进度条（更干净）
#   -S：配合 -s，出错时仍然打印错误信息（否则静默你看不到原因）
#   -L：跟随重定向（GitHub/镜像可能 302）
#   -o：输出到指定文件
# -----------------------------------------------------------------------------
echo "==> Downloading docker-compose.yaml..."
curl -fsSL "${COMPOSE_URL}" -o "${BASE_DIR}/docker-compose.yaml"

# -----------------------------------------------------------------------------
# 下载 subweb 的 config.js 到本地挂载目录
# 重要：这个文件通常用于配置 Subweb 前端的 API 地址等信息
# 若你在 config.js 里写的是 127.0.0.1：
#   - 这是“浏览器所在机器”的 127.0.0.1（即访问页面的客户端），不是容器的 localhost
#   - 如果你从另一台电脑访问 subweb 页面，127.0.0.1 会指向那台电脑自身，导致 API 请求失败
# 因此一般建议 apiUrl 用：
#   - 你的服务器 IP:25500
#   - 或者反代路径（例如同域名 /api）
# 这里脚本只是下载文件，不改内容，但你要知道这个坑在哪。
# -----------------------------------------------------------------------------
echo "==> Downloading subweb config.js to mounted conf/ ..."
curl -fsSL "${CONFIG_URL}" -o "${BASE_DIR}/subweb/conf/config.js"

# -----------------------------------------------------------------------------
# 打印文件信息，方便确认：
#   - 文件是否存在
#   - 是否大小为 0（下载失败/被拦截有时会得到空文件）
#   - 权限是否正常
# -----------------------------------------------------------------------------
echo "==> Files:"
ls -lah "${BASE_DIR}/docker-compose.yaml"
ls -lah "${BASE_DIR}/subweb/conf"
ls -lah "${BASE_DIR}/subweb/conf/config.js"

# -----------------------------------------------------------------------------
# 启动服务前进入部署目录：
# docker compose 会默认读取当前目录下的 docker-compose.yaml（或 compose.yaml）
# 进入 BASE_DIR 确保：
#   - ${DC} up -d 使用的是你刚下载的 compose 文件
#   - 相关相对路径 volume 挂载也以 BASE_DIR 为基准
# -----------------------------------------------------------------------------
echo "==> Starting services..."
cd "${BASE_DIR}"

# -----------------------------------------------------------------------------
# pull：尝试拉取最新镜像
# 这里加了 || true 的原因：
#   - pull 失败不一定要阻止后续 up（例如你已经有镜像、本地可用，或网络临时失败）
#   - 但如果你希望“必须确保拉取成功”，可以去掉 || true
# 注意：你之前遇到过 overlayfs 解压失败（通常是磁盘空间不足或 inode/overlay 问题）
# pull 过程中也可能失败，这里放行后，up 可能仍能用本地已有镜像跑起来。
# -----------------------------------------------------------------------------
${DC} pull || true

# -----------------------------------------------------------------------------
# up -d：按 compose 文件启动（或重建）容器
#   -d：后台运行
# 如果 compose 文件定义了 volume 映射到 subweb/conf，
# 那么你下载的 config.js 会覆盖容器内对应路径，从而使配置生效。
# -----------------------------------------------------------------------------
${DC} up -d

# 空行，美观
echo

# -----------------------------------------------------------------------------
# 查看容器状态：
#   ${DC} ps 会列出服务名、容器名、状态、端口映射等
# 用于快速判断是否启动成功/是否在重启循环
# -----------------------------------------------------------------------------
echo "==> Status:"
${DC} ps

# 空行，美观
echo

# -----------------------------------------------------------------------------
# 提示如何看日志（不自动 tail -f，避免脚本卡住）
# 你可以复制下面两条命令之一查看实时日志：
#   - subweb：前端 nginx 容器日志（通常看访问、静态文件、反代错误）
#   - subconverter：后端服务日志（通常看转换请求、启动报错、端口占用等）
# -----------------------------------------------------------------------------
echo "==> Logs:"
echo "  ${DC} logs -f subweb"
echo "  ${DC} logs -f subconverter"
