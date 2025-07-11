#!/bin/bash

# ==========================================================
# iKuai DHCP 租约导出脚本（带交互式输入与详细注释）
# 功能：通过 iKuai API 获取 DHCP 租约列表并导出为 hosts 格式
# ==========================================================

set -e  # 脚本中任意命令失败即终止执行

# 定义临时 Cookie 文件路径和输出文件路径
COOKIE_FILE="/tmp/ikuai_cookie.txt"  # 临时存放登录 Cookie 的路径
OUTPUT_FILE="/root/mosdns/rules-dat/hosts.txt"  # 最终导出的 hosts 文件路径

# 默认配置（若用户未输入，则使用以下默认值）
DEFAULT_IP="192.168.12.254"  # 默认 iKuai 设备 IP 地址
DEFAULT_USER="admin"          # 默认用户名

# ----------------------------------------------------------
# 1. 用户交互输入（带默认值）
# ----------------------------------------------------------
read -p "请输入 iKuai 的 IP 地址 (默认: $DEFAULT_IP): " IKUAI_HOST
IKUAI_HOST=${IKUAI_HOST:-$DEFAULT_IP}  # 若未输入，使用默认 IP

read -p "请输入 iKuai 的用户名 (默认: $DEFAULT_USER): " IKUAI_USER
IKUAI_USER=${IKUAI_USER:-$DEFAULT_USER}  # 若未输入，使用默认用户名

read -s -p "请输入 iKuai 的密码: " IKUAI_PASS

echo  # 输出空行（仅作格式化）

# ----------------------------------------------------------
# 2. 密码处理（计算 MD5 哈希值）
# ----------------------------------------------------------
PASS_MD5=$(echo -n "$IKUAI_PASS" | md5sum | awk '{print $1}')  # 将密码计算成 MD5 哈希值

# ----------------------------------------------------------
# 3. 登录 iKuai 获取 Cookie
# ----------------------------------------------------------
echo "==> 登录 iKuai..."

# 向 iKuai API 发送登录请求，保存返回的 Cookie 到临时文件
LOGIN_JSON=$(curl -skc "$COOKIE_FILE" -H "Content-Type: application/json" \
  -d "{\"username\":\"$IKUAI_USER\",\"passwd\":\"$PASS_MD5\",\"pass\":\"$IKUAI_USER\"}" \
  "https://$IKUAI_HOST/Action/login")

# 检查登录是否成功（通过 JSON 中的 Result 字段）
if echo "$LOGIN_JSON" | grep -q '"Result":10000'; then
  echo "✅ 登录成功"
else
  echo "❌ 登录失败:"
  echo "$LOGIN_JSON"
  exit 1  # 登录失败则脚本退出
fi

# ----------------------------------------------------------
# 4. 获取 DHCP 租约数据
# ----------------------------------------------------------
echo "==> 获取 DHCP 租约列表..."

# 通过 iKuai API 获取 DHCP 租约列表
DATA_JSON=$(curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
  -d '{"func_name":"dhcp_lease","action":"show","param":{"TYPE":"total,data","ORDER_BY":"timeout","ORDER":"desc","limit":"0,1000"}}' \
  "https://$IKUAI_HOST/Action/call")

# 检查返回的 JSON 数据格式是否正确（防止无法解析的情况）
if ! echo "$DATA_JSON" | jq . >/dev/null 2>&1; then
  echo "❌ 数据格式错误，无法解析 JSON:"
  echo "$DATA_JSON"
  exit 2  # 数据异常则脚本退出
fi

# ----------------------------------------------------------
# 5. 解析并导出数据
# ----------------------------------------------------------
# 从 JSON 提取 hostname 和 IP，过滤空主机名
# 将 URL 编码的空格（%20）替换成实际空格
# 导出为 "hostname ip" 的格式至 hosts 文件

echo "$DATA_JSON" | jq -r '
  .Data.data[] | 
  select(.hostname != "") | 
  "\(.hostname|@uri|gsub("%20"; " ")) \(.ip_addr)"' | sed 's/%20/ /g' > "$OUTPUT_FILE"

# 完成提示

echo "✅ 导出完成：$OUTPUT_FILE"
