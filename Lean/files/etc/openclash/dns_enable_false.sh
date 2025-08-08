#!/bin/sh
# =========================================================
# OpenClash 订阅 DNS 修正脚本（只改 dns: 块 + 跳过主配置 + 备份 + 完整日志）
# 作者：Andy 定制（安全版）
# =========================================================

CONFIG_DIR="/etc/openclash"
LOG_FILE="/etc/openclash/dns_enable_false.log"
CONFIG_PATH="$(uci -q get openclash.config.config_path)"  # 当前生效主配置

# 检查目录是否存在
[ -d "$CONFIG_DIR" ] || exit 0

# 当前执行时间
NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo "=== [执行时间] $NOW ===" >> "$LOG_FILE"

# 仅扫描常见配置位置；你也可以只扫 /etc/openclash/config
FILES="$(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.yaml')"

[ -z "$FILES" ] && {
  echo "未找到任何 YAML 文件，跳过处理" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"
  exit 0
}

for f in $FILES; do
  # 跳过当前生效的主配置（防止误伤运行文件）
  if [ -n "$CONFIG_PATH" ] && [ "$f" = "$CONFIG_PATH" ]; then
    echo "跳过文件: $f (原因：当前生效配置)" >> "$LOG_FILE"
    continue
  fi

  # 仅处理包含 dns: 根键的文件
  if ! grep -qE '^dns:[[:space:]]*$' "$f"; then
    echo "跳过文件: $f (原因：未发现 dns 根配置)" >> "$LOG_FILE"
    continue
  fi

  # 先判断 dns: 块里是否存在 enable: true
  # 用 sed 限定范围：从 dns: 到下一个顶格键（非空格开头）
  if sed -n '/^dns:[[:space:]]*$/,/^[^[:space:]]/p' "$f" | grep -qE '^[[:space:]]+enable:[[:space:]]*true'; then
    cp -p "$f" "$f.bak.$(date +%s)" 2>/dev/null
    # 只在 dns: 块内把 enable: true → false
    sed -i '/^dns:[[:space:]]*$/,/^[^[:space:]]/ s/^\([[:space:]]*enable:[[:space:]]*\)true/\1false/' "$f"
    if sed -n '/^dns:[[:space:]]*$/,/^[^[:space:]]/p' "$f" | grep -qE '^[[:space:]]+enable:[[:space:]]*false'; then
      echo "修改文件: $f (dns.enable: true → false)" >> "$LOG_FILE"
    else
      echo "警告: $f (尝试修改但未检测到结果，请手动检查)" >> "$LOG_FILE"
    fi
  else
    # dns: 块存在但没有 enable: true
    if sed -n '/^dns:[[:space:]]*$/,/^[^[:space:]]/p' "$f" | grep -qE '^[[:space:]]+enable:[[:space:]]*false'; then
      echo "跳过文件: $f (原因：dns.enable 已为 false)" >> "$LOG_FILE"
    else
      echo "跳过文件: $f (原因：dns 块内未发现 enable 字段)" >> "$LOG_FILE"
    fi
  fi
done

echo "" >> "$LOG_FILE"
