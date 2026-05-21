#!/bin/sh

# =====================================================================
# ⚙️ 基础路径与环境配置
# =====================================================================
BASE_DIR="/root"
WORK_DIR="$BASE_DIR/ikuai_cnip_sync"
SCRIPT_NAME="ikuai_cnip_sync.sh"

# 确保工作目录存在
if [ ! -d "$WORK_DIR" ]; then
    echo "📦 正在创建目录..."
    mkdir -p "$WORK_DIR"
fi

# 无论目录是否新建，都确保进入工作目录
cd "$WORK_DIR" || exit 1

# 如果脚本不存在，则下载
if [ ! -f "$SCRIPT_NAME" ]; then
    echo "📥 正在下载同步脚本..."
    wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/ikuai_cnip_sync/ikuai_cnip_sync.sh
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
CRON_JOB="$CRON_MIN $CRON_HOUR * * * /bin/sh $WORK_DIR/$SCRIPT_NAME >> /var/log/ikuai_cnip_sync.log 2>&1"

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
