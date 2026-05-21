#!/bin/sh

# =====================================================================
# ⚙️ 基础路径与环境配置
# =====================================================================
BASE_DIR="/root"
WORK_DIR="$BASE_DIR/ikuai_cnip_sync"

# 确保进入大本营
cd "$BASE_DIR" || exit 1

# =====================================================================
# 🚀 1. 初始化与目录建立
# =====================================================================
if [ ! -d "$WORK_DIR" ]; then
    echo "📦 正在创建目录..."
    mkdir "$WORK_DIR"
    cd "$WORK_DIR" || exit 1
    wget https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/ikuai_cnip_sync/ikuai_cnip_sync.sh
fi

# 🌟 顺手赋予定时任务脚本可执行权限，方便后续 cron 或手动调用
if [ -f "ikuai_cnip_sync.sh" ]; then
    chmod +x ikuai_cnip_sync.sh
fi

# =====================================================================
# ⏰ 2. CRON 定时任务交互式配置
# =====================================================================
echo ""
echo "========================================="
echo "⏰ 开始配置 cron 定时更新任务"
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
CRON_JOB="$CRON_MIN $CRON_HOUR * * * /bin/sh /root/ikuai_cnip_sync/ikuai_cnip_sync.sh >> /var/log/ikuai_cnip_sync.log 2>&1"

# 防重复防覆盖写入法：
# 1. 导出当前 crontab 2. 过滤掉旧的 cron-cfst 记录 3. 追加新记录 4. 重新导入
(crontab -l 2>/dev/null | grep -v "ikuai_cnip_sync.sh"; echo "$CRON_JOB") | crontab -

echo "------------------------------------------------------------------"
echo "✅ 定时任务已成功写入系统 Crontab！"
echo "📅 测速计划：每天 ${CRON_HOUR} 时 ${CRON_MIN} 分 自动运行"
echo "📝 运行日志将输出至: /var/log/ikuai_cnip_sync.log"
echo "------------------------------------------------------------------"

echo "========================================="
echo "🎉 iKuai CN IP 定时更新任务配置全部完成！"
echo "========================================="
