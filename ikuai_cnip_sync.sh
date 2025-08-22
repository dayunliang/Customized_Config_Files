#!/bin/bash
#
# iKuai Domestic IP Sync Tool
#
# 用于同步 GitHub 上的国内 IP 段到 iKuai 自定义运营商 (Domestic)
# 支持 --dry-run 查看差异和 payload，不会真正更新
#

IKUAI_HOST="192.168.12.254"
IKUAI_PROTO="https"
COOKIE_FILE="/tmp/ikuai_cookie.txt"
TMPDIR="/tmp/ikuai_domestic_sync"
#REMOTE_URL="https://raw.githubusercontent.com/17mon/china_ip_list/refs/heads/master/china_ip_list.txt"
REMOTE_URL="https://raw.githubusercontent.com/mayaxcn/china-ip-list/refs/heads/master/chnroute.txt"
IKUAI_USER="admin"
IKUAI_PASS="password"   # <<<<<< 在这里填入你的 iKuai 密码

mkdir -p "$TMPDIR"

# 登录 iKuai
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

# 获取 Domestic ID 列表
get_domestic_ids() {
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"data","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r '.Data.data[] | select(.name=="Domestic") | .id'
}

# 获取 Domestic 完整对象（包含 comment）
get_domestic_obj() {
  local id="$1"
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -c --argjson ID "$id" '.Data.data[] | select(.id==$ID)'
}

# 获取本地 Domestic IP 列表（传入 id）
get_current_ip() {
  local id="$1"
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r --argjson ID "$id" '.Data.data[] | select(.id==$ID) | .ipgroup' \
  | tr ',' '\n' \
  | grep -v '^null$'
}

# 拉取远端 IPv4 列表
get_remote_ip() {
  echo ">>> 拉取远端国内 IP 列表..." >&2
  curl -fsSL "$REMOTE_URL" \
  | sed -E 's/#.*$//' \
  | awk 'NF>0 && $1 !~ /:/' \
  | grep -v '^$'
}

# 更新 Domestic (实际更新 / Dry-run)
update_isp() {
  local id="$1"
  local file="$2"

  # 获取当前对象（含 comment）
  local current
  current=$(get_domestic_obj "$id")

  local comment
  comment=$(echo "$current" | jq -r '.comment')

  ipdata=$(tr '\n' ',' < "$file" | sed 's/,$//')

  local payload="$TMPDIR/update_${id}.json"

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
    echo ">>> [Dry-run] 将提交的 payload 内容如下："
    cat "$payload" | jq .
  else
    echo ">>> 提交更新到 iKuai..."
    curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" \
      --data-binary "@$payload" \
      "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" | jq .
  fi
}

# 获取本地总条目数
get_local_total() {
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r '.Data.data[] | select(.name=="Domestic") | .ipgroup' \
  | tr ',' '\n' \
  | grep -v '^null$' \
  | wc -l
}

# 获取远端总条目数
get_remote_total() {
  curl -fsSL "$REMOTE_URL" \
  | sed -E 's/#.*$//' \
  | awk 'NF>0 && $1 !~ /:/' \
  | grep -v '^$' \
  | wc -l
}

# 主逻辑
main() {
  dry_run=0
  [[ "$1" == "--dry-run" ]] && dry_run=1

  login

  # 获取 Domestic ID 列表
  echo ">>> 获取 Domestic ID..."
  mapfile -t DOMESTIC_IDS < <(get_domestic_ids)
  if [[ ${#DOMESTIC_IDS[@]} -lt 2 ]]; then
    echo "❌ 未找到两个 Domestic，当前数量: ${#DOMESTIC_IDS[@]}"
    exit 1
  fi
  echo "找到 Domestic ID: ${DOMESTIC_IDS[*]}"

  # 获取远端 IPv4
  REMOTE_IP=$(get_remote_ip)
  REMOTE_COUNT=$(echo "$REMOTE_IP" | wc -l)
  echo "远端 IPv4 共 $REMOTE_COUNT 条（已过滤 IPv6）"

  # 拆分 5000 + 剩余
  echo "$REMOTE_IP" | head -n 5000 > "$TMPDIR/remote_part1.txt"
  echo "$REMOTE_IP" | tail -n +5001 > "$TMPDIR/remote_part2.txt"
  echo "Part1: $(wc -l < $TMPDIR/remote_part1.txt) 条"
  echo "Part2: $(wc -l < $TMPDIR/remote_part2.txt) 条"

  # 对比 & 更新
  for i in 0 1; do
    local_id=${DOMESTIC_IDS[$i]}
    remote_file="$TMPDIR/remote_part$((i+1)).txt"
    local_file="$TMPDIR/local$((i+1)).txt"

    echo ">>> 获取当前 id=$local_id 内容..."
    get_current_ip "$local_id" > "$local_file"

    echo "=== id=$local_id 差异 (当前 vs 远端) ==="
    diff -u "$local_file" "$remote_file"

    if [[ $dry_run -eq 0 ]]; then
      if diff -q "$local_file" "$remote_file" >/dev/null; then
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

  # 对比条目数
  local_count=$(get_local_total)
  remote_count=$(get_remote_total)
  echo "=== 条目数统计 ==="
  echo "本地 (local)  Domestic 条目数: $local_count"
  echo "远端 (remote) Domestic 条目数: $remote_count"

  echo ">>> 完成"
}

main "$@"
