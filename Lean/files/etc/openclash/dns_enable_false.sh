#!/bin/sh
# =========================================================
# OpenClash 订阅 DNS 修正脚本（仅修改订阅文件 + 完整日志 + 防呆优化）
# 作用：
#   1. 遍历 /etc/openclash 下所有 .yaml 文件
#   2. 如果存在 "dns: enable: true" 则改为 "dns: enable: false"
#   3. 如果是 enable: false → 提示跳过
#   4. 如果不存在 enable 配置 → 提示跳过
#   5. 空目录时不报错，并记录日志
# 作者：Andy 定制
# =========================================================

CONFIG_DIR="/etc/openclash"
LOG_FILE="/etc/openclash/dns_enable_false.log"

# 检查目录是否存在
[ -d "$CONFIG_DIR" ] || exit 0

# 当前执行时间
NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo "=== [执行时间] $NOW ===" >> "$LOG_FILE"

# 获取 YAML 文件列表（避免空匹配问题）
FILES=$(find "$CONFIG_DIR" -maxdepth 1 -type f -name "*.yaml")

# 如果没有找到 YAML 文件
if [ -z "$FILES" ]; then
    echo "未找到任何 YAML 文件，跳过处理" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    exit 0
fi

# 遍历所有 YAML 文件
for f in $FILES; do
    if grep -qE '^dns:[[:space:]]*$' "$f"; then
        # 1. 如果 enable: true
        if grep -qE '^[[:space:]]+enable:[[:space:]]*true' "$f"; then
            echo "修改文件: $f (enable: true → enable: false)" >> "$LOG_FILE"
            sed -i 's/^\([[:space:]]*enable:[[:space:]]*\)true/\1false/' "$f"

        # 2. 如果 enable: false
        elif grep -qE '^[[:space:]]+enable:[[:space:]]*false' "$f"; then
            echo "跳过文件: $f (原因：enable = false)" >> "$LOG_FILE"

        # 3. 有 dns: 但没有 enable 字段
        else
            echo "跳过文件: $f (原因：未发现 enable 配置)" >> "$LOG_FILE"
        fi
    else
        # 没有 dns: 字段
        echo "跳过文件: $f (原因：未发现 dns 配置)" >> "$LOG_FILE"
    fi
done

echo "" >> "$LOG_FILE"  # 批次执行结束换行
