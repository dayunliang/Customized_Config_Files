#!/bin/bash
#
# iKuai Domestic IP Sync Tool with WeChat Notify
#
# 功能：
#   1. 从 GitHub 拉取国内 IP 列表
#   2. 按 5000 条分片 → 映射到 iKuai 中的多个 Domestic 自定义运营商条目
#   3. 支持 --dry-run 模式（只打印差异和 payload 摘要，不真正更新）
#   4. 当有更新时通过 Server酱推送到微信
#   5. 多个 ID 更新时合并为一条通知，并显示每个分片的本地/远端条目数
#

# ====================== 前置依赖检查 ======================
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ 未检测到 jq，请先安装 jq 后再运行脚本"
  echo "   Alpine: apk add jq"
  echo "   Debian/Ubuntu: apt install -y jq"
  echo "   CentOS/RHEL: yum install -y jq"
  exit 1
fi

# ====================== 基础配置 ======================

IKUAI_HOST="192.168.12.254"     # iKuai 管理地址
IKUAI_PROTO="https"             # 访问协议，通常为 https
COOKIE_FILE="/tmp/ikuai_cookie.txt"   # 登录态 cookie 文件路径
TMPDIR="/tmp/ikuai_domestic_sync"     # 临时文件目录

# 国内 IP 数据源，可以换成其它维护者的列表
#REMOTE_URL="https://raw.githubusercontent.com/17mon/china_ip_list/refs/heads/master/china_ip_list.txt"
REMOTE_URL="https://raw.githubusercontent.com/mayaxcn/china-ip-list/refs/heads/master/chnroute.txt"

IKUAI_USER="admin"              # 登录用户名
IKUAI_PASS="password"           # 登录密码（明文，后面会 md5）

mkdir -p "$TMPDIR"              # 创建临时目录

# ====================== 微信推送 (Server酱) ======================

SENDKEY="SCTxxxxxxxxxxxxxxxxxxxxx"   # <<< 替换成你的 Server酱 SendKey

# notify_wechat 函数：
# 输入一段文本 msg，调用 Server酱接口推送到微信
notify_wechat() {
  local msg="$1"
  curl -s "https://sctapi.ftqq.com/$SENDKEY.send" \
    -d "title=iKuai更新通知" \
    -d "desp=$msg" >/dev/null
}

# ====================== 登录函数 ======================

# login 函数：
# 使用用户名+md5密码登录 iKuai
# 登录成功后 cookie 会写入 COOKIE_FILE
login() {
  echo ">>> 登录 iKuai..."
  PASS_MD5=$(echo -n "$IKUAI_PASS" | md5sum | awk '{print $1}')
  LOGIN_JSON=$(curl -skc "$COOKIE_FILE" -H "Content-Type: application/json" \
    -d "{\"username\":\"$IKUAI_USER\",\"passwd\":\"$PASS_MD5\",\"pass\":\"$IKUAI_PASS\"}" \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/login")

  if echo "$LOGIN_JSON" | grep -q '"Result":10000'; then
    echo "✅ 登录成功"
  else
    echo "❌ 登录失败:"
    echo "$LOGIN_JSON"
    exit 1
  fi
}

# ====================== 获取 iKuai 配置 ======================

# 获取所有名为 "Domestic" 的自定义运营商 ID
get_domestic_ids() {
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"data","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r '.Data.data[] | select(.name=="Domestic") | .id'
}

# 根据 ID 获取 Domestic 条目完整对象（包括注释 comment）
get_domestic_obj() {
  local id="$1"
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -c --argjson ID "$id" '.Data.data[] | select(.id==$ID)'
}

# 获取指定 Domestic 的 ipgroup 字段，并转成换行的 IP 列表
get_current_ip() {
  local id="$1"
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r --argjson ID "$id" '.Data.data[] | select(.id==$ID) | .ipgroup' \
  | tr ',' '\n' \
  | grep -v '^null$'
}

# ====================== 获取远端列表 ======================

# 拉取远端 IP 列表，并清理注释/IPv6/空行
get_remote_ip() {
  echo ">>> 拉取远端国内 IP 列表..." >&2
  curl -fsSL "$REMOTE_URL" \
  | sed -E 's/#.*$//' \
  | awk 'NF>0 && $1 !~ /:/' \
  | grep -v '^$'
}

# ====================== 更新函数 ======================

# update_isp 函数：
# 根据指定 ID 和远端文件内容，生成更新 payload 并提交给 iKuai
update_isp() {
  local id="$1"
  local file="$2"

  local current
  current=$(get_domestic_obj "$id")
  local comment
  comment=$(echo "$current" | jq -r '.comment')

  # 把换行 IP 列表压缩成逗号分隔
  ipdata=$(tr '\n' ',' < "$file" | sed 's/,$//')
  local payload="$TMPDIR/update_${id}.json"

  # 如果原来有注释，则保留
  if [[ -n "$comment" && "$comment" != "null" ]]; then
    cat > "$payload" <<EOF
{
  "func_name": "custom_isp",
  "action": "edit",
  "param": {
    "id": $id,
    "name": "Domestic",
    "comment": "$comment",
    "ipgroup": "$ipdata"
  }
}
EOF
  else
    cat > "$payload" <<EOF
{
  "func_name": "custom_isp",
  "action": "edit",
  "param": {
    "id": $id,
    "name": "Domestic",
    "ipgroup": "$ipdata"
  }
}
EOF
  fi

  if [[ $dry_run -eq 1 ]]; then
    # Dry-run 模式：只显示 payload 摘要（隐藏真实 IP 列表）
    echo ">>> [Dry-run] 将提交的 payload 内容如下："
    jq '(.param.ipgroup_len = (.param.ipgroup | split(",") | length))
        | del(.param.ipgroup)' "$payload"
  else
    # 真正提交更新
    echo ">>> 提交更新到 iKuai..."
    curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" \
      --data-binary "@$payload" \
      "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" | jq .
  fi
}

# ====================== 条目数统计 ======================

# 获取本地 Domestic 总条目数（所有分片加总）
get_local_total() {
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r '.Data.data[] | select(.name=="Domestic") | .ipgroup' \
  | tr ',' '\n' \
  | grep -v '^null$' \
  | wc -l
}

# 获取远端 Domestic 总条目数
get_remote_total() {
  curl -fsSL "$REMOTE_URL" \
  | sed -E 's/#.*$//' \
  | awk 'NF>0 && $1 !~ /:/' \
  | grep -v '^$' \
  | wc -l
}

# ====================== 主逻辑 ======================

main() {
  dry_run=0
  [[ "$1" == "--dry-run" ]] && dry_run=1

  login

  echo ">>> 获取 Domestic ID..."
  mapfile -t DOMESTIC_IDS < <(get_domestic_ids)
  if [[ ${#DOMESTIC_IDS[@]} -lt 2 ]]; then
    echo "❌ 未找到两个 Domestic，当前数量: ${#DOMESTIC_IDS[@]}"
    exit 1
  fi
  echo "找到 Domestic ID: ${DOMESTIC_IDS[*]}"

  # 拉取远端 IP 列表
  REMOTE_IP=$(get_remote_ip)
  REMOTE_COUNT=$(echo "$REMOTE_IP" | wc -l)
  echo "远端 IPv4 共 $REMOTE_COUNT 条"

  # 拆分成两份（每份最多 5000）
  echo "$REMOTE_IP" | head -n 5000 > "$TMPDIR/remote_part1.txt"
  echo "$REMOTE_IP" | tail -n +5001 > "$TMPDIR/remote_part2.txt"
  echo "Part1: $(wc -l < $TMPDIR/remote_part1.txt) 条"
  echo "Part2: $(wc -l < $TMPDIR/remote_part2.txt) 条"

  part_count=$(ls "$TMPDIR"/remote_part*.txt 2>/dev/null | wc -l)
  if (( part_count > ${#DOMESTIC_IDS[@]} )); then
    echo "❌ 错误：远端分片数 $part_count 超过 iKuai 中 Domestic 数 ${#DOMESTIC_IDS[@]}"
    echo "请在 iKuai 中添加更多 Domestic 条目后再执行"
    exit 1
  fi

  update_msg=""   # 汇总推送内容

  for ((i=0; i<part_count; i++)); do
    local_id=${DOMESTIC_IDS[$i]}                # 本地对应的 ID
    remote_file="$TMPDIR/remote_part$((i+1)).txt"
    local_file="$TMPDIR/local$((i+1)).txt"

    echo ">>> 获取当前 id=$local_id 内容..."
    get_current_ip "$local_id" > "$local_file"

    # 获取本地/远端分片条目数
    local_lines=$(wc -l < "$local_file")
    remote_lines=$(wc -l < "$remote_file")

    # 差异条目数 = comm 差集行数
    if [[ -s "$local_file" ]]; then
      diff_count=$(comm -3 <(sort "$local_file") <(sort "$remote_file") | wc -l)
    else
      diff_count=$remote_lines   # 本地为空 → 全部差异
    fi

    echo "=== id=$local_id 差异条目数: $diff_count ==="

    if [[ $dry_run -eq 0 ]]; then
      if [[ $diff_count -eq 0 ]]; then
        echo ">>> ID=$local_id 无需更新"
      else
        echo ">>> 更新 id=$local_id ..."
        update_isp "$local_id" "$remote_file"

        # 收集本分片的更新情况
        update_msg+="Domestic ID=$local_id 已更新  
差异条目数=$diff_count  
本地条目数=$local_lines, 远端条目数=$remote_lines  
执行时间：$(date '+%Y-%m-%d %H:%M:%S')  

"
      fi
    else
      echo ">>> Dry-run 模式，不执行更新，只展示 payload"
      update_isp "$local_id" "$remote_file"
    fi
  done

  # === 循环结束后统一推送一次 ===
  if [[ -n "$update_msg" ]]; then
    notify_wechat "$update_msg"
  fi

  # 统计全局条目数（所有分片）
  local_count=$(get_local_total)
  remote_count=$(get_remote_total)
  echo "=== 条目数统计 ==="
  echo "本地 (local): $local_count"
  echo "远端 (remote): $remote_count"

  echo ">>> 完成"
}

main "$@"
