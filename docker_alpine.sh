#!/bin/sh
# ============================================================================
# 脚本名称：docker_alpine.sh (工业级高可用终极生产力固化版本)
# 功能：在 Alpine Linux 上一键部署 Docker、containerd、Compose、open-vm-tools、git及常用工具
# 亮点：幂等设计、底层彻底自愈、内核桥接与 cgroup2 级固化、容器自启死锁终结、全量验证汇总
# 
# 深度技术注释（后期全新部署备忘）：
#   本脚本核心解决了新版 Docker 在 Alpine OpenRC 架构下的两大底层死锁：
#   1. 控制组委派死锁：通过在 /etc/conf.d 注入合规的 rc_cgroups="NO" 语法，
#      彻底关闭 OpenRC 对容器引擎服务的圈禁，使其在内核豁免的【根节点】运行，根治 Exit 128 闪退。
#   2. 存储层元数据断点死锁：彻底剥离高风险且在优雅关机时易丢失元数据的 containerd-snapshotter，
#      在 daemon.json 中显式强制锁定最经典、最稳固的 "storage-driver": "overlay2"，
#      确保设备不论经历多少次优雅 reboot 还是突发断电，开机恢复容器读写层时绝不爆出 nil 错误。
#
# 更新与维护时间戳：2026-05-31 13:30:00 (Fixed One-Key Deploy Build)
# ============================================================================

set -e

# ---------- 小工具（终端高亮着色显示） ----------
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'
ok()   { printf "${GREEN}✔${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}▲${NC} %s\n" "$*"; }
err()  { printf "${RED}✘${NC} %s\n" "$*"; }
info() { printf "${BLUE}i${NC} %s\n" "$*"; }

# ---------- 通用函数：固定 Alpine 当前大版本软件源，避免 latest-stable 滚动导致库版本混装 ----------
setup_apk_repositories() {
  ALPINE_VER="$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || true)"

  if [ -z "$ALPINE_VER" ]; then
    err "无法读取 /etc/alpine-release，无法判断 Alpine 大版本。"
    exit 1
  fi

  info "检测到当前 Alpine 大版本：v${ALPINE_VER}，将 APK 源固定到该版本，避免 latest-stable 滚动混装。"

  cp /etc/apk/repositories /etc/apk/repositories.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

  cat >/etc/apk/repositories <<EOF
https://mirrors.ustc.edu.cn/alpine/v${ALPINE_VER}/main
https://mirrors.ustc.edu.cn/alpine/v${ALPINE_VER}/community
EOF

  apk update
}

# ---------- 通用函数：安装包时不吞错误，避免“显示安装完成但实际未安装/库错配” ----------
apk_install_required() {
  info "正在安装/补齐必需软件包：$*"
  apk add --no-cache "$@"
}

# ---------- 通用函数：修复 dig/bind 与 OpenSSL/libcrypto 的运行库版本错配 ----------
fix_dig_runtime() {
  info "正在修复并验证 dig/bind-tools 与 OpenSSL/libcrypto 运行库一致性..."

  apk add --no-cache openssl libcrypto3 libssl3 bind-libs bind-tools
  apk fix openssl libcrypto3 libssl3 bind-libs bind-tools >/dev/null 2>&1 || true

  if command -v dig >/dev/null 2>&1 && dig -v >/dev/null 2>&1; then
    ok "dig 运行时验证通过：$(dig -v 2>/dev/null)"
    return 0
  fi

  warn "dig 首次验证失败，准备强制重装 bind 相关组件以消除库错配..."
  apk del bind-tools bind-libs >/dev/null 2>&1 || true
  apk add --no-cache openssl libcrypto3 libssl3 bind-libs bind-tools

  if command -v dig >/dev/null 2>&1 && dig -v >/dev/null 2>&1; then
    ok "dig 强制重装后验证通过：$(dig -v 2>/dev/null)"
  else
    err "dig 仍不可用，请执行：dig -v，并检查 libcrypto/libssl 是否来自同一 Alpine 版本源。"
    exit 1
  fi
}

# ---------- Docker 运行时底层环境自愈检测函数 ----------
ensure_docker_runtime_ready() {
  # 关闭强制退出，允许内部自检逻辑安全向下探测与容错
  set +e

  REPORT="/root/docker_runtime_fix_$(date +%Y%m%d_%H%M%S).log"
  touch "$REPORT"

  wait_sock() {
    N="${1:-15}"
    i=0
    while [ $i -lt $N ]; do
      [ -S /var/run/docker.sock ] && return 0
      i=$((i+1))
      sleep 1
    done
    return 1
  }

  restart_daemons() {
    rc-service docker stop >/dev/null 2>&1 || true
    rc-service containerd stop >/dev/null 2>&1 || true
    # 强力清理可能残留的 OCI 运行时任务死锁挂载点
    rm -rf /run/containerd/io.containerd.runtime.v2.task/moby/* >/dev/null 2>&1 || true
    rc-service containerd start >/dev/null 2>&1 || true
    rc-service docker start >/dev/null 2>&1 || true
    wait_sock 15 || return 1
    return 0
  }

  docker_info_brief() {
    docker info 2>/dev/null | awk '
      /Server Version/ || /Default Runtime/ || /Storage Driver/ || /Backing Filesystem/ || /Cgroup Version/ {print}
    '
  }

  info "[自愈层] 检查并补齐必需底层依赖工具（jq、libseccomp）..."
  apk add --no-cache jq libseccomp >/dev/null 2>&1 || true

  info "[自愈层] 正在持久化刷新 cgroups v2 统一拓扑与内核虚拟桥接模块..."
  modprobe overlay 2>/dev/null || true
  modprobe br_netfilter 2>/dev/null || true
  
  # 【自愈补丁 1】：修改 Alpine 全局配置，将控制组强制锁定在 v2 Unified 模式下
  if grep -q "rc_cgroup_mode=" /etc/rc.conf; then
    sed -i 's/.*rc_cgroup_mode=.*/rc_cgroup_mode="unified"/' /etc/rc.conf
  else
    echo 'rc_cgroup_mode="unified"' >> /etc/rc.conf
  fi
  
  # 【自愈补丁 2】：理顺辈分！将 cgroups 强行绑定在 boot 引导级，阻止其与 Docker 抢跑
  rc-update add cgroups boot >/dev/null 2>&1 || true
  rc-service cgroups start  >/dev/null 2>&1 || true
  
  # 【自愈补丁 3】：解除 OpenRC 的 cgroup 圈禁枷锁，强制让其驻留根节点（清除历史错误配置残留）
  mkdir -p /etc/conf.d
  touch /etc/conf.d/docker /etc/conf.d/containerd
  sed -i '/rc_cgroup_mode=/d' /etc/conf.d/docker 2>/dev/null || true
  sed -i '/rc_cgroup_mode=/d' /etc/conf.d/containerd 2>/dev/null || true
  sed -i '/rc_cgroups=/d' /etc/conf.d/docker 2>/dev/null || true
  sed -i '/rc_cgroups=/d' /etc/conf.d/containerd 2>/dev/null || true
  echo 'rc_cgroups="NO"' >> /etc/conf.d/docker
  echo 'rc_cgroups="NO"' >> /etc/conf.d/containerd

  sysctl -w net.bridge.bridge-nf-call-iptables=1  >/dev/null 2>&1 || true
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true

  info "[自愈层] 规范 /etc/docker/daemon.json 并强制锁定稳定存储驱动..."
  mkdir -p /etc/docker
  [ -s /etc/docker/daemon.json ] || echo '{}' > /etc/docker/daemon.json
  cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
  
  # 【自愈补丁 4】：剔除所有毒素参数，纠正为正宗官方 overlay2 驱动 + 独立控制组路径
  jq 'del(.runtimes) | del(."containerd-snapshotter") | ."default-runtime"="io.containerd.runc.v2" | ."cgroup-parent"="/docker-containers" | ."storage-driver"="overlay2"' \
    /etc/docker/daemon.json > /etc/docker/daemon.json.new && \
    mv /etc/docker/daemon.json.new /etc/docker/daemon.json
  ok "daemon.json 配置规范自愈完毕（经典 overlay2 驱动已成功锁定）"

  info "[自愈层] 重启守护进程并激活动态 Socket..."
  if restart_daemons; then
    ok "dockerd socket 响应成功，就绪。"
  else
    err "dockerd socket 未出现，自愈模块遭遇阻碍。正在转储调试快照日志：$REPORT"
    echo "==== docker.log ====" >> "$REPORT"
    tail -n 200 /var/log/docker.log >> "$REPORT" 2>&1
  fi

  info "当前 Docker 运行上下文快照："
  docker_info_brief || true

  info "尝试运行 hello-world 进行环境契约验证（阶段 A：io.containerd.runc.v2）..."
  if docker run --rm hello-world >/dev/null 2>&1; then
    ok "hello-world 完美通过（io.containerd.runc.v2 契约达成）。"
    PASSED=1
  else
    warn "阶段 A 失败，检测到本地 runc 静态链接或依赖缺失，进入阶段 B 深度依赖强补齐..."
    PASSED=0
  fi

  if [ "$PASSED" -eq 0 ]; then
    RUNC_OK=1
    if [ -x /usr/bin/runc ]; then
      /usr/bin/runc --version >/dev/null 2>&1 || RUNC_OK=0
    else
      RUNC_OK=0
    fi
    if [ "$RUNC_OK" -eq 0 ]; then
      warn "确认 runc 异常，强制重新补充 libseccomp 底层安全隔离库..."
      apk add --no-cache libseccomp >/dev/null 2>&1 || true
    fi
    info "重构进程上下文后再次尝试 hello-world（仍首选 io.containerd.runc.v2）..."
    restart_daemons || true
    if docker run --rm hello-world >/dev/null 2>&1; then
      ok "hello-world 成功通过（经过 B 阶段补齐修复后，io.containerd.runc.v2 生效）。"
      PASSED=1
    else
      warn "阶段 B 仍未通过，进入阶段 C 最高容错预案：原地兜底切换至低耗轻量化 crun 运行时。"
    fi
  fi

  if [ "$PASSED" -eq 0 ]; then
    info "正在释放部署 crun 包，并重置全局默认 runtime 为 crun 拓扑..."
    apk add --no-cache crun >/dev/null 2>&1 || true
    jq '
      ."default-runtime"="crun" |
      ."cgroup-parent"="/docker-containers" |
      ."storage-driver"="overlay2" |
      .runtimes = (.runtimes // {}) |
      .runtimes.crun.path="/usr/bin/crun"
    ' /etc/docker/daemon.json > /etc/docker/daemon.json.new && \
    mv /etc/docker/daemon.json.new /etc/docker/daemon.json

    restart_daemons || true

    info "尝试运行 hello-world（crun 备用容错链路验证）..."
    if docker run --rm hello-world >/dev/null 2>&1; then
      ok "hello-world 成功通过（crun 备用链路完美兜底）。"
      PASSED=2
    else
      err "工业级三阶段自愈链路全部耗尽。强制将底层堆栈死锁日志导出至 $REPORT"
      echo "==== docker.log ====" >> "$REPORT"
      tail -n 200 /var/log/docker.log >> "$REPORT" 2>&1
    fi
  fi

  echo >> "$REPORT"
  docker info >> "$REPORT" 2>&1 || true

  echo
  if [ "$PASSED" -eq 1 ]; then
    ok "【最终环境判定】：默认 runtime=io.containerd.runc.v2 (Runc 纯正模式可用) ✅"
    docker_info_brief
  elif [ "$PASSED" -eq 2 ]; then
    ok "【最终环境判定】：已成功激活工业级兜底弹性预案，默认 runtime=crun ✅"
    docker_info_brief
  else
    err "【最终环境判定】：运行时环境重度死锁，未通过自愈链路 ❌"
  fi

  # 恢复标准严格错误捕获机制，确保主线流程安全
  set -e
}

# ---------- 0. 权限校验模块 ----------
info "检查当前终端执行权限是否为最高 root 权限..."
if [ "$(id -u)" != "0" ]; then
  err "错误：请使用 root 账号执行本脚本。"; exit 1
fi

# ---------- 1. APK 官方软件源优化 ----------
info "正在对 Alpine 官方源进行中科大 (USTC) 高速镜像源幂等性重构..."
setup_apk_repositories

# 先做一次全量可用升级，确保已安装的 openssl/libcrypto/bind-libs 不会停留在旧版本。
# 这一步是修复 dig 报 EVP_MD_CTX_get_size_ex symbol not found 的关键。
info "正在同步升级当前系统已安装包，避免新旧运行库混装..."
apk upgrade --available

# ---------- 2. 联合合并集中式安装组件 ----------
info "联合批量安装基础运维工具、高级网络协议组件及 Docker 底层前置虚拟化依赖..."
# 不再使用 >/dev/null 2>&1 || true 吞掉安装错误，任何关键包安装失败都应立即暴露。
apk_install_required \
  docker containerd runc openrc iptables ip6tables jq curl bash vim htop ca-certificates \
  git openssh-client bind-tools bind-libs openssl libcrypto3 libssl3 \
  open-vm-tools open-vm-tools-guestinfo open-vm-tools-deploypkg \
  musl-locales musl-locales-lang less net-tools c-ares nftables docker-cli-compose

fix_dig_runtime
ok "基础及高级运维网络组件联合集成安装完成"

# ---------- 3. 全局系统中文环境本地化与 Vim 字符集优化 ----------
info "配置系统全局中文 UTF-8 字符环境本地化与 Vim 文本编辑器默认字符集编码..."
cat >/etc/profile.d/locale.sh <<'EOF'
export LANG=zh_CN.UTF-8
export LC_CTYPE=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8
EOF
chmod +x /etc/profile.d/locale.sh
. /etc/profile.d/locale.sh

mkdir -p /etc/vim
cat >/etc/vim/vimrc <<'EOF'
set encoding=utf-8
set termencoding=utf-8
set fileencoding=utf-8
set fileencodings=ucs-bom,utf-8,default,latin1
EOF
ok "系统中文环境本地化与 Vim 强字符集契约锁定完成"

# ---------- 4. OpenRC 系统服务开机启动管理层固化 ----------
info "正在向 OpenRC 服务管理架构注册核心进程开机排队自启契约..."

if grep -q "rc_cgroup_mode=" /etc/rc.conf; then
  sed -i 's/.*rc_cgroup_mode=.*/rc_cgroup_mode="unified"/' /etc/rc.conf
else
  echo 'rc_cgroup_mode="unified"' >> /etc/rc.conf
fi

# 理顺长幼尊卑：让 cgroups 服务单独加入最高优先级的 boot 核心级，把底座铺平
rc-update add cgroups boot || true
rc-update add containerd default || true
rc-update add docker default || true
rc-update add open-vm-tools boot || true

# 立即启动 open-vm-tools，否则后面的健康检查会误判为未通过
rc-service open-vm-tools start >/dev/null 2>&1 || true

# 【终极正确修正】：永久固化单服务豁免开关，强令 OpenRC 关闭对 Docker/Containerd 的圈禁，使其在根节点拿到全量特权
mkdir -p /etc/conf.d
touch /etc/conf.d/docker /etc/conf.d/containerd
sed -i '/rc_cgroup_mode=/d' /etc/conf.d/docker 2>/dev/null || true
sed -i '/rc_cgroup_mode=/d' /etc/conf.d/containerd 2>/dev/null || true
sed -i '/rc_cgroups=/d' /etc/conf.d/docker 2>/dev/null || true
sed -i '/rc_cgroups=/d' /etc/conf.d/containerd 2>/dev/null || true
grep -q 'rc_cgroups="NO"' /etc/conf.d/docker || echo 'rc_cgroups="NO"' >> /etc/conf.d/docker
grep -q 'rc_cgroups="NO"' /etc/conf.d/containerd || echo 'rc_cgroups="NO"' >> /etc/conf.d/containerd

# ---------- 5. Docker 核心虚拟化守护引擎配置 ----------
info "正在配置 /etc/docker/daemon.json (国内多路镜像加速 + 焊死锁定 overlay2 老牌经典存储驱动) ..."
mkdir -p /etc/docker
[ -f /etc/docker/daemon.json ] || echo '{}' > /etc/docker/daemon.json
cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
cat >/tmp/daemon.patch.json <<'JSON'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.com",
    "https://mirror.baidubce.com",
    "https://docker.nju.edu.cn",
    "https://docker.mirrors.sjtu.edu.cn",
    "https://mirror.iscas.ac.cn"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "iptables": true,
  "default-runtime": "io.containerd.runc.v2",
  "cgroup-parent": "/docker-containers",
  "storage-driver": "overlay2"
}
JSON
jq -s '.[0] * .[1]' /etc/docker/daemon.json /tmp/daemon.patch.json > /etc/docker/daemon.json.new
mv /etc/docker/daemon.json.new /etc/docker/daemon.json
rm -f /tmp/daemon.patch.json

# ---------- 6. Containerd 容器高级运行时配置 ----------
info "正在规范配置 /etc/containerd/config.toml (强绑定默认运行时意图名位 runc)..."
if [ ! -s /etc/containerd/config.toml ]; then
  containerd config default >/etc/containerd/config.toml
fi
sed -i -E 's#(^\s*default_runtime_name\s*=\s*).*$#\1"runc"#' /etc/containerd/config.toml || true

# ---------- 7. Linux 内核高级虚拟化网桥网络与 cgroup2 契约激活 ----------
info "正在开启 Linux 内核桥接层过滤 netfilter 与 cgroup2 联动模块..."
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true
mkdir -p /etc/sysctl.d
tee /etc/sysctl.d/99-docker-bridge.conf >/dev/null <<'SYS'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
SYS
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true

# ---------- 8. 现代 Docker Compose 高级编排引擎集成自动化 ----------
info "正在检测并智能化集成现代化 Docker Compose 容器集群高级编排引擎..."
if ! docker compose version >/dev/null 2>&1; then
  apk_install_required docker-cli-compose
fi

# ---------- 9. Homelab 专属私有仓库磁盘监控高级脚本自动化拉取与部署 ----------
# 默认保留原有私有仓库磁盘监控脚本部署逻辑。
# 若只想纯一键部署 Docker 环境、不想在 SSH 公钥授权处交互阻塞，可这样执行：
#   SKIP_PRIVATE_DISK_MONITOR=1 sh docker_alpine_fixed_onekey.sh
if [ "${SKIP_PRIVATE_DISK_MONITOR:-0}" = "1" ]; then
    warn "已按 SKIP_PRIVATE_DISK_MONITOR=1 跳过私有磁盘监控脚本部署。"
else
info "开始配置磁盘监控脚本部署环境 (从 GitHub 私有配置仓库临时稀疏提取)..."
REPO_PRIVATE_TMP="/root/.private_config_repo_tmp"
TARGET_BIN_PATH="/usr/bin/disk_space_check.dingtalk"
FILE_NAME="disk_space_check.dingtalk"

SSH_KEY_FOUND=0
PUB_KEY_PATH=""
for KEY_TYPE in "id_ed25519.pub" "id_rsa.pub"; do
    if [ -f "$HOME/.ssh/$KEY_TYPE" ]; then
        SSH_KEY_FOUND=1
        PUB_KEY_PATH="$HOME/.ssh/$KEY_TYPE"
        break
    fi
done

if [ "$SSH_KEY_FOUND" -eq 0 ]; then
    warn "未探查到本地 SSH 运维密钥对，正在为您自发自动化构建高安全性非对称 Ed25519 密钥对..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "cron@homelab.local" -N "" -f "$HOME/.ssh/id_ed25519"
    PUB_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    ok "非对称 Ed25519 密钥对构建成功！"
fi

echo "------------------------------------------------------------------"
warn "📢 运维动作提示：请完整复制以下公钥并将其绑定至您的 GitHub 账户或私有仓库中："
echo "   👉 账户全局路径: GitHub -> Settings -> SSH and GPG keys -> New SSH key"
echo "------------------------------------------------------------------"
cat "$PUB_KEY_PATH"
echo "------------------------------------------------------------------"
echo -n "⚠️  当您在 GitHub 端完成上述部署公钥的绑定授权后，请敲击 [回车键] 结束阻塞继续后续安装流程..."
read CONFIRM_SSH

rm -rf "$REPO_PRIVATE_TMP"
info "📦 正在与 GitHub 私有配置仓库建立安全握手并进行稀疏零碎文件拉取..."
git clone --filter=blob:none --no-checkout git@github.com:dayunliang/private_config.git "$REPO_PRIVATE_TMP"
cd "$REPO_PRIVATE_TMP" || exit 1
git sparse-checkout init --no-cone
git sparse-checkout set "$FILE_NAME"
git checkout main || true
cd /root

if [ -f "$REPO_PRIVATE_TMP/$FILE_NAME" ]; then
    rm -f "$TARGET_BIN_PATH"
    mv "$REPO_PRIVATE_TMP/$FILE_NAME" "$TARGET_BIN_PATH"
    chmod +x "$TARGET_BIN_PATH"
    rm -rf "$REPO_PRIVATE_TMP"
    ok "磁盘空间高级监控脚本已成功安全固化至系统执行路径：$TARGET_BIN_PATH"
    
    info "⏰ 正在为该监控脚本准备动态写入配置系统 Crontab 高级调度池..."
    echo "------------------------------------------------------------------"
    echo "请选择您的私有磁盘监控脚本在 Homelab 宿主机中的周期执行频率计划："
    echo "  1) 每隔 1小时 调度运行一次 (0 * * * *)"
    echo "  2) 每隔 6小时 调度运行一次 (0 */6 * * *)  [工业级推荐/直接回车默认选择]"
    echo "  3) 每天凌晨 2:00 准点调度运行一次 (0 2 * * *)"
    echo "  4) 我想亲自自定义编写 5 位标准高精度 Cron 表达式"
    echo "------------------------------------------------------------------"
    echo -n "请输入您的计划计划选项代号 [1-4] (直接回车保持默认推荐计划): "
    read CRON_CHOICE

    case "$CRON_CHOICE" in
        1)  CRON_TIME="0 * * * *" ;;
        3)  CRON_TIME="0 2 * * *" ;;
        4)  echo ""
            echo -n "请输入标准的 5 位 Cron 表达式 (例如 '0 */3 * * *'): "
            read CUSTOM_CRON
            if [ -z "$CUSTOM_CRON" ]; then CRON_TIME="0 */6 * * *"; else CRON_TIME="$CUSTOM_CRON"; fi ;;
        *)  CRON_TIME="0 */6 * * *" ;;
    esac

    CRON_JOB_DISK="$CRON_TIME $TARGET_BIN_PATH >> ~/disk_space_check.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$FILE_NAME"; echo "$CRON_JOB_DISK") | crontab -
    ok "系统核心 Crontab 调度任务池固化配置成功！当前时间表被锁定为: [$CRON_TIME]"
else
    rm -rf "$REPO_PRIVATE_TMP"
    err "❌ 严重部署失败：未能拉取到目标脚本，请检查仓库权限！"
fi
fi

# ---------- 10. 运行时自愈检测层全面激活校验 ----------
ensure_docker_runtime_ready

# ---------- 11. 环境交叉扫描验证与健康汇总摘要 ----------
REPORT_SUM="/root/docker_env_report_$(date +%Y%m%d_%H%M%S).txt"
PASS=1
echo "Docker & Tools Environment Comprehensive Report - $(date)" > "$REPORT_SUM"

check() {
  DESC="$1"; CMD="$2"
  if sh -c "$CMD" >/dev/null 2>&1; then
    ok "[通过] $DESC"; printf "[PASS] %s\n" "$DESC" >> "$REPORT_SUM"
  else
    PASS=0; err "[未过] $DESC"; printf "[FAIL] %s\n" "$DESC" >> "$REPORT_SUM"
  fi
}

info "开始对系统当前环境进行最终多维交叉扫描验证..."
check "Docker 核心底座引擎整体可用性检查" "docker version"
check "Containerd 高级容器运行时服务活动状态" "rc-service containerd status | grep -q 'status: started' || pgrep containerd"
check "Docker Daemon 守护进程后台健康存活状态" "rc-service docker status | grep -q 'status: started' || pgrep dockerd"
check "Open-VM-Tools 虚拟化客户机高级守护进程状态" "rc-service open-vm-tools status | grep -q 'status: started' || pgrep vmtoolsd"
check "Git 分布式版本控制小工具执行可用性" "git --version"
check "Linux 内核高级虚拟网桥虚拟转发层桥接开启契约验证 (iptables=1)" "[ \"\$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)\" = 1 ]"
check "Docker 虚拟化隔离沙箱最底层容器实例冷启动链路跑通性验证" "docker run --rm hello-world"
check "Dig 高级 DNS 运维排查小工具可用性" "command -v dig >/dev/null 2>&1 && dig -v >/dev/null 2>&1"

if [ $PASS -eq 1 ]; then
  printf "\n"
  ok "恭喜！全量多维核心环境验证交叉扫描圆满通过！底座已处于完美无错状态！✅"
  echo "🧾 审计白皮书报告已生成：$REPORT_SUM"
  echo "💡 运维动作提示：现在请重新拉起你的容器组合，随后即可放心 reboot 体验永不闪退的闭环！"
else
  printf "\n"
  err "警告：环境扫描存在未通过项，请核对日志！❌"
  exit 2
fi
