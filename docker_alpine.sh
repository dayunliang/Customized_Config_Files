#!/bin/sh
# ============================================================================
# 脚本名称：docker_alpine.sh
# 功能：在 Alpine Linux 上一键部署 Docker、containerd、Compose、open-vm-tools、git及常用工具
# 亮点：幂等、安全、桥接与 cgroup 初始化、镜像加速、验证汇总
#       内置 ensure_docker_runtime_ready：优先 io.containerd.runc.v2，失败兜底 crun
# 作者：https://github.com/dayunliang（由 AI 补充 open-vm-tools 与 git）
# 日期：2026-05-19
# ============================================================================

set -e

# ---------- 小工具（着色） ----------
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'
ok()   { printf "${GREEN}✔${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}▲${NC} %s\n" "$*"; }
err()  { printf "${RED}✘${NC} %s\n" "$*"; }
info() { printf "${BLUE}i${NC} %s\n" "$*"; }

# ---------- runtime 自愈（整合自 fix.sh） ----------
ensure_docker_runtime_ready() {
  # 不要让内部失败导致主脚本退出
  set +e

  REPORT="/root/docker_runtime_fix_$(date +%Y%m%d_%H%M%S).log"
  touch "$REPORT"

  wait_sock() {
    N="${1:-15}"; i=0
    while [ $i -lt $N ]; do
      [ -S /var/run/docker.sock ] && return 0
      i=$((i+1)); sleep 1
    done
    return 1
  }

  restart_daemons() {
    rc-service docker stop >/dev/null 2>&1 || true
    rc-service containerd stop >/dev/null 2>&1 || true
    rm -rf /run/containerd/io.containerd.runtime.v2.task/moby/* >/dev/null 2>&1 || true
    rc-service containerd start >/dev/null 2>&1 || true
    rc-service docker start >/dev/null 2>&1 || true
    wait_sock 15 || return 1
    return 0
  }

  docker_info_brief() {
    docker info 2>/dev/null | awk '
      /Server Version|Default Runtime|Storage Driver|Backing Filesystem|Cgroup Version/ {print}
    '
  }

  info "安装必需工具（jq、libseccomp）..."
  apk add --no-cache jq libseccomp >/dev/null 2>&1 || true

  info "准备内核模块与 cgroup v2 / bridge-nf..."
  modprobe overlay 2>/dev/null || true
  modprobe br_netfilter 2>/dev/null || true
  mkdir -p /sys/fs/cgroup
  mount | grep -q "type cgroup2" || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
  rc-update add cgroups default >/dev/null 2>&1 || true
  rc-service cgroups start  >/dev/null 2>&1 || true
  sysctl -w net.bridge.bridge-nf-call-iptables=1  >/dev/null 2>&1 || true
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true

  info "规范 /etc/docker/daemon.json（删除 runtimes，自设 default-runtime=io.containerd.runc.v2）..."
  mkdir -p /etc/docker
  [ -s /etc/docker/daemon.json ] || echo '{}' > /etc/docker/daemon.json
  cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
  jq 'del(.runtimes) | ."default-runtime"="io.containerd.runc.v2"' \
    /etc/docker/daemon.json > /etc/docker/daemon.json.new && \
    mv /etc/docker/daemon.json.new /etc/docker/daemon.json
  ok "daemon.json 已清理并设定 default-runtime=io.containerd.runc.v2"

  info "重启 containerd/docker 并等待 socket ..."
  if restart_daemons; then
    ok "dockerd socket就绪。"
  else
    err "dockerd socket 未出现。查看日志：$REPORT"
    echo "==== docker.log ====" >> "$REPORT"; tail -n 200 /var/log/docker.log >> "$REPORT" 2>&1
    echo "==== containerd.log ====" >> "$REPORT"; tail -n 200 /var/log/containerd.log >> "$REPORT" 2>&1
  fi

  info "当前 docker 关键信息："
  docker_info_brief || true

  info "尝试运行 hello-world（阶段 A：io.containerd.runc.v2）..."
  if docker run --rm hello-world >/dev/null 2>&1; then
    ok "hello-world 成功（io.containerd.runc.v2）。"
    PASSED=1
  else
    warn "阶段 A 失败，检查 runc 可执行性并修复依赖（阶段 B）..."
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
      warn "runc 不可执行或缺依赖，补齐 libseccomp ..."
      apk add --no-cache libseccomp >/dev/null 2>&1 || true
    fi
    info "重启服务后再次尝试 hello-world（仍使用 io.containerd.runc.v2）..."
    restart_daemons || true
    if docker run --rm hello-world >/dev/null 2>&1; then
      ok "hello-world 成功（修复后，io.containerd.runc.v2）。"
      PASSED=1
    else
      warn "阶段 B 仍失败，进入阶段 C：兜底切换 crun。"
    fi
  fi

  if [ "$PASSED" -eq 0 ]; then
    info "安装 crun 并切换默认 runtime=crun ..."
    apk add --no-cache crun >/dev/null 2>&1 || true
    jq '
      ."default-runtime"="crun" |
      .runtimes = (.runtimes // {}) |
      .runtimes.crun.path="/usr/bin/crun"
    ' /etc/docker/daemon.json > /etc/docker/daemon.json.new && \
    mv /etc/docker/daemon.json.new /etc/docker/daemon.json

    restart_daemons || true

    info "尝试 hello-world（crun）..."
    if docker run --rm hello-world >/dev/null 2>&1; then
      ok "hello-world 成功（crun）。"
      PASSED=2
    else
      err "hello-world 仍失败。导出日志到 $REPORT"
      echo "==== docker.log ====" >> "$REPORT"; tail -n 200 /var/log/docker.log >> "$REPORT" 2>&1
      echo "==== containerd.log ====" >> "$REPORT"; tail -n 200 /var/log/containerd.log >> "$REPORT" 2>&1
    fi
  fi

  echo >> "$REPORT"
  docker info >> "$REPORT" 2>&1 || true

  echo
  if [ "$PASSED" -eq 1 ]; then
    ok "最终结果：默认 runtime=io.containerd.runc.v2 ✅"
    docker_info_brief
    echo "报告：$REPORT"
  elif [ "$PASSED" -eq 2 ]; then
    ok "最终结果：已兜底切换默认 runtime=crun ✅"
    docker_info_brief
    echo "报告：$REPORT"
  else
    err "最终结果：仍失败 ❌"
    echo "请检查：/var/log/docker.log、/var/log/containerd.log、$REPORT"
    # 不让主脚本失败
  fi

  # 恢复 set -e
  set -e
}

# ---------- 0. Root ----------
info "检查是否为 root 用户..."
if [ "$(id -u)" != "0" ]; then
  err "请使用 root 执行本脚本。"; exit 1
fi

# ---------- 1. APK 源 ----------
info "设置 APK 镜像源为 USTC..."
tee /etc/apk/repositories <<-'EOF'
https://mirrors.ustc.edu.cn/alpine/latest-stable/main
https://mirrors.ustc.edu.cn/alpine/latest-stable/community
EOF

info "更新索引..."
apk update

# ---------- 2. 安装组件 ----------
info "安装 Docker / open-vm-tools / git / 常用工具..."
apk add --no-cache docker containerd runc openrc iptables ip6tables jq curl bash vim htop ca-certificates \
  git open-vm-tools open-vm-tools-guestinfo open-vm-tools-deploypkg

# ---------- 3. 开机自启 ----------
info "设置 containerd / docker / open-vm-tools 开机自启..."
rc-update add containerd default || true
rc-update add docker default || true
rc-update add cgroups default || true
rc-update add open-vm-tools boot || true

# ---------- 4. Docker 配置（镜像加速 + default-runtime 占位） ----------
info "配置 /etc/docker/daemon.json（镜像加速 + 默认 runtime 占位）..."
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
  "default-runtime": "io.containerd.runc.v2"
}
JSON
# 注意：不写入 .runtimes.runc（避免 “runtime name 'runc' is reserved”）
jq -s '.[0] * .[1]' /etc/docker/daemon.json /tmp/daemon.patch.json > /etc/docker/daemon.json.new
mv /etc/docker/daemon.json.new /etc/docker/daemon.json
rm -f /tmp/daemon.patch.json

# ---------- 5. containerd 配置（仅设 default_runtime_name，避免额外 options 警告） ----------
info "配置 /etc/containerd/config.toml（default_runtime_name=runc）..."
if [ ! -s /etc/containerd/config.toml ]; then
  containerd config default >/etc/containerd/config.toml
fi
sed -i -E 's#(^\s*default_runtime_name\s*=\s*).*$#\1"runc"#' /etc/containerd/config.toml || true

# ---------- 6. netfilter 桥 + cgroup2 ----------
info "开启 bridge-nf 与 cgroup2..."
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true
mkdir -p /etc/sysctl.d
tee /etc/sysctl.d/99-docker-bridge.conf >/dev/null <<'SYS'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
SYS
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true
mkdir -p /sys/fs/cgroup
mount | grep -q "type cgroup2" || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true

# ---------- 7. 干净重启 ----------
info "干净重启 open-vm-tools/containerd/docker..."
rc-service open-vm-tools start || true
rc-service docker stop || true
rc-service containerd stop || true
rm -rf /run/containerd/io.containerd.runtime.v2.task/moby/* 2>/dev/null || true
rc-service containerd start
rc-service docker start

# ---------- 8. 安装 Compose ----------
info "安装 Docker Compose..."
if command -v docker-compose >/dev/null 2>&1; then
  ok "已存在 docker-compose（v1）。"
else
  if ! docker compose version >/dev/null 2>&1; then
    info "尝试 apk 安装 docker-cli-compose（v2）..."
    if apk add --no-cache docker-cli-compose >/dev/null 2>&1; then
      ok "已安装 Compose v2（docker compose）。"
    else
      warn "apk 安装失败，回退 GitHub 二进制（v1）..."
      DOCKER_COMPOSE_VERSION="$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f4 || true)"
      [ -z "$DOCKER_COMPOSE_VERSION" ] && DOCKER_COMPOSE_VERSION="1.29.2"
      URL="https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
      curl -L "$URL" -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
      ok "安装完成：docker-compose ${DOCKER_COMPOSE_VERSION}"
    fi
  else
    ok "已存在 Compose v2（docker compose）。"
  fi
fi

# ---------- 9. 运行时自愈 + 自检 ----------
ensure_docker_runtime_ready

# ---------- 10. 最终环境验证与汇总 ----------
REPORT_SUM="/root/docker_env_report_$(date +%Y%m%d_%H%M%S).txt"
PASS=1
echo "Docker & Tools Environment Report - $(date)" > "$REPORT_SUM"

check() {
  DESC="$1"; CMD="$2"
  if sh -c "$CMD" >/dev/null 2>&1; then
    ok "$DESC"; printf "[PASS] %s\n" "$DESC" >> "$REPORT_SUM"
  else
    PASS=0; err "$DESC"; printf "[FAIL] %s\n" "$DESC" >> "$REPORT_SUM"
  fi
}

info "开始最终环境验证..."
check "docker 可用" "docker version"
check "containerd 运行" "rc-service containerd status | grep -q 'status: started' || pgrep containerd"
check "docker daemon 运行" "rc-service docker status | grep -q 'status: started' || pgrep dockerd"
check "open-vm-tools 运行" "rc-service open-vm-tools status | grep -q 'status: started' || pgrep vmtoolsd"
check "git 工具可用" "git --version"
check "bridge-nf-call-iptables=1" "[ \"\$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)\" = 1 ]"
check "bridge-nf-call-ip6tables=1" "[ \"\$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)\" = 1 ]"
check "hello-world 可运行" "docker run --rm hello-world"

if docker compose version >/dev/null 2>&1; then
  ok "Compose v2 可用"; echo "[PASS] Compose v2 available" >> "$REPORT_SUM"
elif docker-compose version >/dev/null 2>&1; then
  ok "Compose v1 可用"; echo "[PASS] Compose v1 available" >> "$REPORT_SUM"
else
  PASS=0; err "未检测到 Compose"; echo "[FAIL] Compose missing" >> "$REPORT_SUM"
fi

if docker info 2>/dev/null | grep -A20 "Registry Mirrors" | grep -E 'https?://'; then
  ok "已配置 Registry Mirrors"; echo "[PASS] Registry mirrors configured" >> "$REPORT_SUM"
else
  warn "未检测到 Registry Mirrors"; echo "[WARN] No registry mirrors detected" >> "$REPORT_SUM"
fi

echo "" >> "$REPORT_SUM"
if [ $PASS -eq 1 ]; then
  ok "环境验证通过 ✅"
  echo "[SUMMARY] ALL CHECKS PASSED" >> "$REPORT_SUM"
  echo "🧾 报告文件：$REPORT_SUM"
else
  err "环境验证未全部通过 ❌"
  echo "[SUMMARY] SOME CHECKS FAILED" >> "$REPORT_SUM"
  echo "🧾 报告文件：$REPORT_SUM"
  exit 2
fi
