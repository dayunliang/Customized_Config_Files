#!/bin/bash
#
# iKuai Domestic IP Sync Tool
#
# 功能：
#   1. 从 GitHub 拉取国内 IP 段列表
#   2. 按 5000 条为一组分片，对应 iKuai 中的多个自定义运营商 (Domestic)
#   3. 支持 --dry-run 模式：只显示差异条数和 payload 摘要，不真正更新
#   4. 安全检查：如果分片数超过 iKuai 中的 Domestic 数量，直接报错退出
#
# 说明：
#   - iKuai 限制单个自定义运营商最多 5000 条 IP
#   - 脚本会自动拆分远端 IP 列表，存放到多个 Domestic 条目中
#   - 建议至少准备 2 个 Domestic（一个 5000 条，一个存放剩余）
#

# ====================== 基础配置 ======================

IKUAI_HOST="192.168.12.254"     # iKuai 地址
IKUAI_PROTO="https"             # 使用的协议（http/https）
COOKIE_FILE="/tmp/ikuai_cookie.txt"   # 保存 iKuai 登录会话的 Cookie 文件
TMPDIR="/tmp/ikuai_domestic_sync"     # 临时目录，存放远端/本地/分片文件

# 国内 IP 数据源
# 可切换为 17mon/china_ip_list 等其它维护者的项目
#REMOTE_URL="https://raw.githubusercontent.com/17mon/china_ip_list/refs/heads/master/china_ip_list.txt"
REMOTE_URL="https://raw.githubusercontent.com/mayaxcn/china-ip-list/refs/heads/master/chnroute.txt"

IKUAI_USER="admin"              # iKuai 登录用户名
IKUAI_PASS="password"           # iKuai 登录密码（注意：直接写在脚本里有安全风险）

mkdir -p "$TMPDIR"              # 确保临时目录存在

# ====================== 登录函数 ======================

login() {
  echo ">>> 登录 iKuai..."
  # iKuai 要求密码同时传明文和 MD5 值
  PASS_MD5=$(echo -n "$IKUAI_PASS" | md5sum | awk '{print $1}')
  LOGIN_JSON=$(curl -skc "$COOKIE_FILE" -H "Content-Type: application/json" \
    -d "{\"username\":\"$IKUAI_USER\",\"passwd\":\"$PASS_MD5\",\"pass\":\"$IKUAI_PASS\"}" \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/login")

  # 登录成功返回 JSON 包含 Result=10000
  if echo "$LOGIN_JSON" | grep -q '"Result":10000'; then
    echo "✅ 登录成功"
  else
    echo "❌ 登录失败:"
    echo "$LOGIN_JSON"
    exit 1
  fi
}

# ====================== 获取 iKuai 配置 ======================

# 获取所有 Domestic 条目的 ID 列表
get_domestic_ids() {
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"data","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r '.Data.data[] | select(.name=="Domestic") | .id'
}

# 获取指定 ID 的完整对象（包含 comment 字段）
get_domestic_obj() {
  local id="$1"
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -c --argjson ID "$id" '.Data.data[] | select(.id==$ID)'
}

# 获取指定 ID 的本地 IP 列表
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

get_remote_ip() {
  echo ">>> 拉取远端国内 IP 列表..." >&2
  # 步骤：
  # 1. 去掉注释行（以 # 开头）
  # 2. 去掉 IPv6 地址（包含冒号的行）
  # 3. 去掉空行
  curl -fsSL "$REMOTE_URL" \
  | sed -E 's/#.*$//' \
  | awk 'NF>0 && $1 !~ /:/' \
  | grep -v '^$'
}

# ====================== 更新函数 ======================

update_isp() {
  local id="$1"     # iKuai 的 Domestic ID
  local file="$2"   # 该分片对应的远端 IP 文件

  # 获取当前对象，用来读取 comment（备注信息）
  local current
  current=$(get_domestic_obj "$id")
  local comment
  comment=$(echo "$current" | jq -r '.comment')

  # 将文件里的 IP 转成逗号分隔的字符串
  ipdata=$(tr '\n' ',' < "$file" | sed 's/,$//')

  local payload="$TMPDIR/update_${id}.json"

  # 构造 payload，保持原有的 comment
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

  # Dry-run 模式只显示摘要，不打印 ipgroup
  if [[ $dry_run -eq 1 ]]; then
    echo ">>> [Dry-run] 将提交的 payload 内容如下："
    jq '(.param.ipgroup_len = (.param.ipgroup | split(",") | length))
        | del(.param.ipgroup)' "$payload"
  else
    echo ">>> 提交更新到 iKuai..."
    curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" \
      --data-binary "@$payload" \
      "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" | jq .
  fi
}

# ====================== 条目数统计 ======================

# 统计本地 Domestic 条目数
get_local_total() {
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r '.Data.data[] | select(.name=="Domestic") | .ipgroup' \
  | tr ',' '\n' \
  | grep -v '^null$' \
  | wc -l
}

# 统计远端 IP 总数
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

  # 获取 iKuai 中的 Domestic ID
  echo ">>> 获取 Domestic ID..."
  mapfile -t DOMESTIC_IDS < <(get_domestic_ids)
  if [[ ${#DOMESTIC_IDS[@]} -lt 2 ]]; then
    echo "❌ 未找到两个 Domestic，当前数量: ${#DOMESTIC_IDS[@]}"
    exit 1
  fi
  echo "找到 Domestic ID: ${DOMESTIC_IDS[*]}"

  # 拉取远端列表
  REMOTE_IP=$(get_remote_ip)
  REMOTE_COUNT=$(echo "$REMOTE_IP" | wc -l)
  echo "远端 IPv4 共 $REMOTE_COUNT 条"

  # 按 5000 条拆分成两个文件
  echo "$REMOTE_IP" | head -n 5000 > "$TMPDIR/remote_part1.txt"
  echo "$REMOTE_IP" | tail -n +5001 > "$TMPDIR/remote_part2.txt"
  echo "Part1: $(wc -l < $TMPDIR/remote_part1.txt) 条"
  echo "Part2: $(wc -l < $TMPDIR/remote_part2.txt) 条"

  # 安全检查：分片数不能超过 Domestic 数量
  part_count=$(ls "$TMPDIR"/remote_part*.txt 2>/dev/null | wc -l)
  if (( part_count > ${#DOMESTIC_IDS[@]} )); then
    echo "❌ 错误：远端分片数 $part_count 超过 iKuai 中 Domestic 数 ${#DOMESTIC_IDS[@]}"
    echo "请在 iKuai 中添加更多 Domestic 条目后再执行"
    exit 1
  fi

  # 遍历每个分片，逐一对比并更新
  for ((i=0; i<part_count; i++)); do
    local_id=${DOMESTIC_IDS[$i]}
    remote_file="$TMPDIR/remote_part$((i+1)).txt"
    local_file="$TMPDIR/local$((i+1)).txt"

    echo ">>> 获取当前 id=$local_id 内容..."
    get_current_ip "$local_id" > "$local_file"

    # 只统计差异条目数，不输出具体 IP
    diff_count=$(comm -3 <(sort "$local_file") <(sort "$remote_file") | wc -l)
    echo "=== id=$local_id 差异条目数: $diff_count ==="

    if [[ $dry_run -eq 0 ]]; then
      if [[ $diff_count -eq 0 ]]; then
        echo ">>> ID=$local_id 无需更新"
      else
        echo ">>> 更新 id=$local_id ..."
        update_isp "$local_id" "$remote_file"
      fi
    else
      echo ">>> Dry-run 模式，不执行更新，只展示 payload"
      update_isp "$local_id" "$remote_file"
    fi
  done

  # 最终统计
  local_count=$(get_local_total)
  remote_count=$(get_remote_total)
  echo "=== 条目数统计 ==="
  echo "本地 (local): $local_count"
  echo "远端 (remote): $remote_count"

  echo ">>> 完成"
}

main "$@"
