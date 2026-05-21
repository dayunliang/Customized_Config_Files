#!/bin/sh

# =====================================================================
# ⚙️ 基础路径与环境配置
# =====================================================================
BASE_DIR="/root"
WORK_DIR="$BASE_DIR/ikuai_cnip_sync"
SCRIPT_NAME="ikuai_cnip_sync.sh"
PRIVATE_FILE="ikuai_cnip_sync.sh.Beverly"
PRIVATE_REPO="git@github.com:dayunliang/private_config.git"

# 确保工作目录存在
if [ ! -d "$WORK_DIR" ]; then
    echo "📦 正在创建目录..."
    mkdir -p "$WORK_DIR"
fi

# 无论目录是否新建，都确保进入工作目录
cd "$WORK_DIR" || exit 1

# 如果脚本不存在，则通过 SSH 从私人仓库下载
if [ ! -f "$SCRIPT_NAME" ]; then
    echo "📥 正在通过 SSH 稀疏检出私人仓库中的定制脚本..."
    
    # 1. 创建一个临时的 git 目录，避免污染当前工作目录
    TEMP_GIT_DIR=".temp_git"
    mkdir -p "$TEMP_GIT_DIR" && cd "$TEMP_GIT_DIR" || exit 1
    
    # 2. 初始化并配置稀疏检出
    git init -q
    git remote add origin "$PRIVATE_REPO"
    git config core.sparseCheckout true
    echo "$PRIVATE_FILE" >> .git/info/sparse-checkout
    
    # 3. 拉取文件并处理
    if git pull origin main -q 2>/dev/null; then
        # 将私人脚本移动到上一级目录，并重命名为标准脚本名
        cp "$PRIVATE_FILE" "../$SCRIPT_NAME"
        cd ..
        rm -rf "$TEMP_GIT_DIR"
        echo "✅ 私人定制脚本下载并配置成功！"
    else
        # 失败处理
        cd ..
        rm -rf "$TEMP_GIT_DIR"
        echo "❌ 错误：通过 SSH 下载失败！请检查："
        echo "   1. 当前设备是否安装了 git"
        echo "   2. 当前设备的 SSH Key 是否已添加到 GitHub 账户"
        echo "   3. 可以运行 'ssh -T git@github.com' 来测试 SSH 连接"
        exit 1
    fi
fi

# 🌟 赋予定时任务脚本可执行权限
if [ -f "$SCRIPT_NAME" ]; then
    chmod +x "$SCRIPT_NAME"
else
    echo "❌ 错误：未找到 $SCRIPT_NAME 脚本，请检查网络或链接是否有效！"
    exit 1
fi

# =====================================================================
# ⏰ 2. CRON 定时任务交互式配置
# =====================================================================
echo ""
echo "========================================="
echo "⏰ 开始配置 cron 定时更新任务"
echo "========================================="

# 交互式获取小时（带合法性校验）
while true; do
    echo -n "   请输入每天执行的 [小时] (0-23，默认凌晨 2 点): "
    read INPUT_HOUR
    if [ -z "$INPUT_HOUR" ]; then
        CRON_HOUR="2"
        break
    fi
    # 确保是 0-23 的纯数字
    if echo "$INPUT_HOUR" | grep -qE '^[0-9]+$' && [ "$INPUT_HOUR" -le 23 ]; then
        CRON_HOUR="$INPUT_HOUR"
        break
    fi
    echo "⚠️  输入无效，请输入 0 到 23 之间的数字！"
done

# 交互式获取分钟（带合法性校验）
while true; do
    echo -n "   请输入执行的 [分钟] (0-59，默认 0 分): "
    read INPUT_MIN
    if [ -z "$INPUT_MIN" ]; then
        CRON_MIN="0"
        break
    fi
    # 确保是 0-59 的纯数字
    if echo "$INPUT_MIN" | grep -qE '^[0-9]+$' && [ "$INPUT_MIN" -le 59 ]; then
        CRON_MIN="$INPUT_MIN"
        break
    fi
    echo "⚠️  输入无效，请输入 0 到 59 之间的数字！"
done

# 组装标准的 Cron 表达式（使用绝对路径预防环境变量问题）
CRON_JOB="$CRON_MIN $CRON_HOUR * * * /bin/bash $WORK_DIR/$SCRIPT_NAME >> /var/log/ikuai_cnip_sync.log 2>&1"

# 防重复防覆盖写入法：过滤旧记录，追加新记录
(crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME"; echo "$CRON_JOB") | crontab -

echo "------------------------------------------------------------------"
echo "✅ 定时任务已成功写入系统 Crontab！"
echo "📅 同步计划：每天 ${CRON_HOUR} 时 ${CRON_MIN} 分 自动运行"
echo "📝 运行日志将输出至: /var/log/ikuai_cnip_sync.log"
echo "------------------------------------------------------------------"

echo "========================================="
echo "🎉 iKuai CN IP 定时更新任务配置全部完成！"
echo "========================================="
