#!/bin/sh

# =====================================================================
# CFST + OpenClash 自动更新部署脚本【每日一次 cron 版】
# 修改时间：2026-06-07  Asia/Shanghai / UTC+8
# =====================================================================
#
# 本脚本职责：
#   1. 检查 / 生成 GitHub SSH Key；
#   2. clone 或更新公开配置仓库 dayunliang/Customized_Config_Files；
#   3. sparse-checkout 只拉取 cfst 目录；
#   4. 建立 /root/cfst -> /root/.config_repo/cfst 软链接；
#   5. clone 或更新私人仓库 dayunliang/private_config；
#   6. 拉取 CFST docker compose 镜像；
#   7. 只写入 1 条每日 cron；
#   8. cron 每次执行时调用 /root/cfst/cron-cfst.sh。
#
# 注意：
#   - 本脚本只负责部署环境和写入定时任务；
#   - 真正执行测速、合并 OpenClash YAML、提交 private_config 的逻辑，
#     在 cron-cfst.sh 中完成。
#
# =====================================================================

set -eu

# =====================================================================
# 1. 基础路径与仓库配置
# =====================================================================

BASE_DIR="/root"
PUBLIC_REPO_DIR="$BASE_DIR/.config_repo"
PUBLIC_REPO_SSH="git@github.com:dayunliang/Customized_Config_Files.git"
WORK_DIR="$BASE_DIR/cfst"

PRIVATE_REPO_DIR="$BASE_DIR/private_config"
PRIVATE_REPO_SSH="git@github.com:dayunliang/private_config.git"

CRON_SCRIPT="$WORK_DIR/cron-cfst.sh"
CRON_LOG="/var/log/cron-cfst.log"

cd "$BASE_DIR" || exit 1

# =====================================================================
# 2. 基础依赖自检与补齐
# =====================================================================
#
# Alpine 环境下尽量自动补齐脚本需要的基础工具：
#   git              用于拉取和提交仓库；
#   openssh-client   用于 SSH 方式访问 GitHub；
#   curl             用于 DingTalk 通知；
#   python3          用于解析和合并 OpenClash YAML 文本；
#   docker-cli-compose 用于 docker compose。
#
# 如果不是 Alpine，脚本不会强行安装，只给出提示。
#
# =====================================================================

echo "🔎 正在检查基础依赖..."

if command -v apk >/dev/null 2>&1; then
    apk add --no-cache git openssh-client curl python3 docker-cli-compose >/dev/null
else
    echo "⚠️  未检测到 apk。请确认系统已安装 git、ssh、curl、python3、docker compose。"
fi

# =====================================================================
# 3. SSH Key 检查与 GitHub 授权提示
# =====================================================================

echo "🔎 正在检查 SSH 密钥状态..."

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
    echo "❌ 未检测到本地 SSH 密钥，正在自动生成 Ed25519 密钥对..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "cron@homelab.local" -N "" -f "$HOME/.ssh/id_ed25519"
    PUB_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    echo "✅ SSH 密钥生成成功。"
fi

echo "------------------------------------------------------------------"
echo "📢 请确认以下公钥已经添加到 GitHub："
echo "   GitHub -> Settings -> SSH and GPG keys -> New SSH key"
echo "------------------------------------------------------------------"
cat "$PUB_KEY_PATH"
echo "------------------------------------------------------------------"
echo -n "⚠️  确认 GitHub 已完成 SSH Key 绑定后，按 [回车键] 继续..."
read CONFIRM_SSH

# 预先把 github.com 写入 known_hosts，避免 cron 首次执行时卡在交互确认。
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true

# =====================================================================
# 4. 初始化 / 更新公开配置仓库
# =====================================================================
#
# 公开仓库：dayunliang/Customized_Config_Files
# 本地目录：/root/.config_repo
# 只拉取：cfst 目录
# 软链接：/root/cfst -> /root/.config_repo/cfst
#
# =====================================================================

if [ ! -d "$PUBLIC_REPO_DIR/.git" ]; then
    echo "📦 正在初始化公开配置仓库：$PUBLIC_REPO_DIR"
    rm -rf "$PUBLIC_REPO_DIR"
    git clone --filter=blob:none --sparse "$PUBLIC_REPO_SSH" "$PUBLIC_REPO_DIR"
    git -C "$PUBLIC_REPO_DIR" sparse-checkout set cfst
else
    echo "🔄 正在更新公开配置仓库：$PUBLIC_REPO_DIR"
    git -C "$PUBLIC_REPO_DIR" fetch origin main
    git -C "$PUBLIC_REPO_DIR" pull --rebase --autostash origin main
    git -C "$PUBLIC_REPO_DIR" sparse-checkout set cfst
fi

rm -f "$WORK_DIR"
ln -s "$PUBLIC_REPO_DIR/cfst" "$WORK_DIR"

if [ ! -d "$WORK_DIR" ]; then
    echo "❌ 错误：$WORK_DIR 不存在，请确认公开仓库中包含 cfst 目录。"
    exit 1
fi

# 确保 cron 脚本可执行。
if [ -f "$CRON_SCRIPT" ]; then
    chmod +x "$CRON_SCRIPT"
else
    echo "⚠️  未找到 $CRON_SCRIPT。请确认 cron-cfst.sh 已提交到公开仓库 cfst 目录。"
fi

# =====================================================================
# 5. 初始化 / 更新私人配置仓库
# =====================================================================
#
# 私人仓库：dayunliang/private_config
# 目标文件：Lean/files/etc/openclash/config/Personal_Use_ALL.yaml
#
# cron-cfst.sh 后续会在此仓库中修改并 push Personal_Use_ALL.yaml。
#
# =====================================================================

if [ ! -d "$PRIVATE_REPO_DIR/.git" ]; then
    echo "🔐 正在初始化私人配置仓库：$PRIVATE_REPO_DIR"
    rm -rf "$PRIVATE_REPO_DIR"
    git clone "$PRIVATE_REPO_SSH" "$PRIVATE_REPO_DIR"
else
    echo "🔄 正在更新私人配置仓库：$PRIVATE_REPO_DIR"
    git -C "$PRIVATE_REPO_DIR" fetch origin main
    git -C "$PRIVATE_REPO_DIR" pull --rebase --autostash origin main
fi

# =====================================================================
# 6. 拉取 CFST Docker 镜像并清理旧容器
# =====================================================================

cd "$WORK_DIR" || exit 1

if [ -f "docker-compose.yml" ] || [ -f "compose.yml" ]; then
    echo "🐳 正在拉取 CFST Docker 镜像..."
    docker compose pull || true
    docker compose down --remove-orphans || true
else
    echo "⚠️  未找到 docker-compose.yml / compose.yml，跳过 Docker 镜像拉取。"
fi

# =====================================================================
# 7. Cron 定时任务交互式配置【每日一次】
# =====================================================================

echo ""
echo "========================================="
echo "⏰ 开始配置 CFST 每日一次 cron 定时任务"
echo "========================================="
echo "说明：本部署脚本只写入 1 条 cron。"
echo "      每次 cron 执行时都会先拉取 GitHub 最新配置，再测速并更新 private_config。"
echo ""

is_valid_hour() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    if [ "$1" -ge 0 ] && [ "$1" -le 23 ]; then
        return 0
    fi

    return 1
}

is_valid_minute() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac

    if [ "$1" -ge 0 ] && [ "$1" -le 59 ]; then
        return 0
    fi

    return 1
}

while true; do
    echo -n "   请输入每天执行的 [小时] (0-23，默认 4 点): "
    read INPUT_HOUR
    if [ -z "$INPUT_HOUR" ]; then
        INPUT_HOUR="4"
    fi
    if is_valid_hour "$INPUT_HOUR"; then
        CRON_HOUR="$INPUT_HOUR"
        break
    fi
    echo "   ❌ 小时输入不合法，请输入 0-23 之间的整数。"
done

while true; do
    echo -n "   请输入每天执行的 [分钟] (0-59，默认 0 分): "
    read INPUT_MINUTE
    if [ -z "$INPUT_MINUTE" ]; then
        INPUT_MINUTE="0"
    fi
    if is_valid_minute "$INPUT_MINUTE"; then
        CRON_MINUTE="$INPUT_MINUTE"
        break
    fi
    echo "   ❌ 分钟输入不合法，请输入 0-59 之间的整数。"
done

CRON_COMMENT="# CFST_OPENCLASH_AUTO_CRON"
CRON_JOB="$CRON_MINUTE $CRON_HOUR * * * /bin/sh $CRON_SCRIPT >> $CRON_LOG 2>&1"

(
    crontab -l 2>/dev/null | grep -v "cron-cfst.sh" | grep -v "cron_cfst.sh" | grep -v "CFST_AUTO_CRON" | grep -v "CFST_OPENCLASH_AUTO_CRON"
    echo "$CRON_COMMENT"
    echo "$CRON_JOB"
) | crontab -

echo "------------------------------------------------------------------"
echo "✅ 每日一次定时任务已成功写入系统 Crontab。"
echo "📅 执行时间：每天 ${CRON_HOUR} 时 ${CRON_MINUTE} 分"
echo "🧾 调用脚本：$CRON_SCRIPT"
echo "📝 运行日志：$CRON_LOG"
echo "------------------------------------------------------------------"
echo "📌 当前 CFST 相关 crontab 内容："
crontab -l 2>/dev/null | grep -A 1 "CFST_OPENCLASH_AUTO_CRON" || true

echo "========================================="
echo "🎉 CFST + OpenClash 自动更新部署完成！"
echo "========================================="
