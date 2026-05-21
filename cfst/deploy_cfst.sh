#!/bin/sh

# =====================================================================
# ⚙️ 基础路径与环境配置
# =====================================================================
BASE_DIR="/root"
REPO_DIR="$BASE_DIR/.config_repo"
WORK_DIR="$BASE_DIR/cfst"

# 确保进入大本营
cd "$BASE_DIR" || exit 1

# =====================================================================
# 🔑 1. SSH KEY 检查与 GitHub 提示
# =====================================================================
echo "🔎 正在检查 SSH 密钥状态..."
SSH_KEY_FOUND=0
PUB_KEY_PATH=""

# 遍历寻找常见的公钥文件
for KEY_TYPE in "id_ed25519.pub" "id_rsa.pub"; do
    if [ -f "$HOME/.ssh/$KEY_TYPE" ]; then
        SSH_KEY_FOUND=1
        PUB_KEY_PATH="$HOME/.ssh/$KEY_TYPE"
        break
    fi
done

if [ "$SSH_KEY_FOUND" -eq 0 ]; then
    echo "❌ 未检测到本地 SSH 密钥，正在为你自动生成 Ed25519 密钥对..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    # 生成免密匙密钥
    ssh-keygen -t ed25519 -C "cron@homelab.local" -N "" -f "$HOME/.ssh/id_ed25519"
    PUB_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    echo "✅ 密钥生成成功！"
fi

# 打印公钥并提示用户去 GitHub 绑定
echo "------------------------------------------------------------------"
echo "📢 请复制以下公钥并添加至您的 GitHub 账户："
echo "   👉 路径: Settings -> SSH and GPG keys -> New SSH key"
echo "------------------------------------------------------------------"
cat "$PUB_KEY_PATH"
echo "------------------------------------------------------------------"
echo -n "⚠️  请确保已在 GitHub 完成绑定，按 [回车键] 继续后续部署..."
read CONFIRM_SSH

# =====================================================================
# 🚀 2. 隐形初始化与仓库建立
# =====================================================================
if [ ! -d "$REPO_DIR" ]; then
    echo "📦 正在初始化隐藏代码仓库壳子..."
    git clone --filter=blob:none --sparse git@github.com:dayunliang/Customized_Config_Files.git "$REPO_DIR"
    cd "$REPO_DIR" || exit 1
    git sparse-checkout set cfst
fi

# 2.1 🌟 强制重置软链接大门
rm -f "$WORK_DIR"
ln -s "$REPO_DIR/cfst" "$WORK_DIR"

# 2.2 🎯 精准切入你的工作目录
cd "$WORK_DIR" || exit 1

# 2.3 同步云端最新的代码和配置
echo "🔄 正在同步云端最新配置..."
git pull origin main

# 2.4 🌟 顺手赋予定时任务脚本可执行权限，方便后续 cron 或手动调用
if [ -f "cron-cfst.sh" ]; then
    chmod +x cron-cfst.sh
fi

# 2.5 拉取最新的测速镜像并清理旧容器
echo "🐳 正在更新 Docker 测速镜像..."
docker compose pull
docker compose down --remove-orphans

# =====================================================================
# ⏰ 3. CRON 定时任务交互式配置
# =====================================================================
echo ""
echo "========================================="
echo "⏰ 开始配置 cron 定时测速任务"
echo "========================================="

# 交互式获取小时
echo -n "   请输入每天执行的 [小时] (0-23，默认凌晨 2 点): "
read INPUT_HOUR
if [ -z "$INPUT_HOUR" ]; then
    CRON_HOUR="2"
else
    CRON_HOUR="$INPUT_HOUR"
fi

# 交互式获取分钟
echo -n "   请输入执行的 [分钟] (0-59，默认 0 分): "
read INPUT_MIN
if [ -z "$INPUT_MIN" ]; then
    CRON_MIN="0"
else
    CRON_MIN="$INPUT_MIN"
fi

# 组装标准的 Cron 表达式（包含绝对路径和日志重定向）
CRON_JOB="$CRON_MIN $CRON_HOUR * * * /bin/sh /root/cfst/cron-cfst.sh >> /var/log/cron-cfst.log 2>&1"

# 防重复防覆盖写入法：
# 1. 导出当前 crontab 2. 过滤掉旧的 cron-cfst 记录 3. 追加新记录 4. 重新导入
(crontab -l 2>/dev/null | grep -v "cron-cfst.sh"; echo "$CRON_JOB") | crontab -

echo "------------------------------------------------------------------"
echo "✅ 定时任务已成功写入系统 Crontab！"
echo "📅 测速计划：每天 ${CRON_HOUR} 时 ${CRON_MIN} 分 自动运行"
echo "📝 运行日志将输出至: /var/log/cron-cfst.log"
echo "------------------------------------------------------------------"

echo "========================================="
echo "🎉 CFST 环境部署与定时任务配置全部完成！"
echo "========================================="
