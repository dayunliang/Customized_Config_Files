#!/bin/bash
#
# iKuai Domestic IP Sync Tool with WeChat Notify
#

# ====================== 前置依赖检查 ======================
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ 未检测到 jq，请先安装 jq 后再运行脚本"
  exit 1
fi

# ====================== 基础配置 ======================
IKUAI_HOST="192.168.12.254"
IKUAI_PROTO="https"
COOKIE_FILE="/tmp/ikuai_cookie.txt"
TMPDIR="/tmp/ikuai_domestic_sync"
REMOTE_URL="https://raw.githubusercontent.com/mayaxcn/china-ip-list/refs/heads/master/chnroute.txt"
IKUAI_USER="admin"
IKUAI_PASS="password"

mkdir -p "$TMPDIR"

# ====================== 微信推送 ======================
SENDKEY="SCTxxxxxxxxxxxxxxxxxxxxx"
notify_wechat() {
  local msg="$1"
  curl -s "https://sctapi.ftqq.com/$SENDKEY.send" \
    -d "title=iKuai更新通知" \
    -d "desp=$msg" >/dev/null
}

# ====================== 登录函数 ======================
login() {
  echo ">>> 登录 iKuai..."
  PASS_MD5=$(echo -n "$IKUAI_PASS" | md5sum | awk '{print $1}')
  LOGIN_JSON=$(curl -skc "$COOKIE_FILE" -H "Content-Type: application/json" \
    -d "{\"username\":\"$IKUAI_USER\",\"passwd\":\"$PASS_MD5\",\"pass\":\"$IKUAI_PASS\"}" \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/login")

  if echo "$LOGIN_JSON" | grep -q '"Result":10000'; then
    echo "✅ 登录成功"
  else
    echo "❌ 登录失败:"; echo "$LOGIN_JSON"; exit 1
  fi
}

# ====================== 获取 iKuai 配置 ======================
get_domestic_ids() {
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"data","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r '.Data.data[] | select(.name=="Domestic") | .id'
}

get_domestic_obj() {
  local id="$1"
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -c --argjson ID "$id" '.Data.data[] | select(.id==$ID)'
}

get_current_ip() {
  local id="$1"
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r --argjson ID "$id" '.Data.data[] | select(.id==$ID) | .ipgroup' \
  | tr ',' '\n' | grep -v '^null$'
}

# ====================== 获取远端列表 ======================
get_remote_ip() {
  curl -fsSL "$REMOTE_URL" | sed -E 's/#.*$//' | awk 'NF>0 && $1 !~ /:/' | grep -v '^$'
}

# ====================== 更新函数 ======================
update_isp() {
  local id="$1"; local file="$2"
  local current comment ipdata payload

  current=$(get_domestic_obj "$id")
  comment=$(echo "$current" | jq -r '.comment')
  ipdata=$(tr '\n' ',' < "$file" | sed 's/,$//')
  payload="$TMPDIR/update_${id}.json"

  if [[ -n "$comment" && "$comment" != "null" ]]; then
    cat > "$payload" <<EOF
{"func_name":"custom_isp","action":"edit","param":{"id":$id,"name":"Domestic","comment":"$comment","ipgroup":"$ipdata"}}
EOF
  else
    cat > "$payload" <<EOF
{"func_name":"custom_isp","action":"edit","param":{"id":$id,"name":"Domestic","ipgroup":"$ipdata"}}
EOF
  fi

  if [[ $dry_run -eq 1 ]]; then
    echo ">>> [Dry-run] Payload 摘要："
    jq '(.param.ipgroup_len=(.param.ipgroup|split(",")|length))|del(.param.ipgroup)' "$payload"
  else
    echo ">>> 提交更新到 iKuai..."
    curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" \
         --data-binary "@$payload" "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" | jq .
  fi
}

# ====================== 条目数统计 ======================
get_local_total() {
  curl -sk -b "$COOKIE_FILE" -H "Content-Type: application/json" -X POST \
    -d '{"func_name":"custom_isp","action":"show","param":{"TYPE":"all","limit":"0,5000"}}' \
    "${IKUAI_PROTO}://${IKUAI_HOST}/Action/call" \
  | jq -r '.Data.data[] | select(.name=="Domestic") | .ipgroup' \
  | tr ',' '\n' | grep -v '^null$' | wc -l
}

get_remote_total() {
  curl -fsSL "$REMOTE_URL" | sed -E 's/#.*$//' | awk 'NF>0 && $1 !~ /:/' | grep -v '^$' | wc -l
}

# ====================== 主逻辑 ======================
main() {
  dry_run=0; [[ "$1" == "--dry-run" ]] && dry_run=1

  echo "================================================================"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始执行任务"

  login

  mapfile -t DOMESTIC_IDS < <(get_domestic_ids)
  if [[ ${#DOMESTIC_IDS[@]} -lt 2 ]]; then
    echo "❌ 未找到两个 Domestic"; exit 1
  fi

  REMOTE_IP=$(get_remote_ip)
  echo "$REMOTE_IP" | head -n 5000 > "$TMPDIR/remote_part1.txt"
  echo "$REMOTE_IP" | tail -n +5001 > "$TMPDIR/remote_part2.txt"

  before_count=$(get_local_total)
  total_diff=0

  for ((i=0;i<2;i++)); do
    local_id=${DOMESTIC_IDS[$i]}
    remote_file="$TMPDIR/remote_part$((i+1)).txt"
    local_file="$TMPDIR/local$((i+1)).txt"
    get_current_ip "$local_id" > "$local_file"

    if [[ -s "$local_file" ]]; then
      diff_count=$(comm -3 <(sort "$local_file") <(sort "$remote_file") | wc -l)
    else
      diff_count=$(wc -l < "$remote_file")
    fi
    total_diff=$((total_diff+diff_count))

    if [[ $dry_run -eq 0 && $diff_count -gt 0 ]]; then
      update_isp "$local_id" "$remote_file"
    elif [[ $dry_run -eq 1 ]]; then
      echo ">>> Dry-run: ID=$local_id 差异=$diff_count"
      update_isp "$local_id" "$remote_file"
    fi
  done

  after_count=$(get_local_total)
  remote_count=$(get_remote_total)

  if [[ $total_diff -eq 0 ]]; then
    echo ">>> [结果] 无更新"
    echo "Local=$before_count  Remote=$remote_count"
  else
    echo ">>> [结果] 有更新，共 $total_diff 条"
    echo "更新前=$before_count  更新后=$after_count"
  fi

  echo ">>> 完成"
  echo "================================================================"
}

main "$@"
