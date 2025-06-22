#!/bin/sh
# ------------------------------------------------------------------------------
# Script Name: clean_ports.sh
# 功能：检查并释放指定端口被占用的容器或系统进程
# 参数：支持通过命令行传入多个端口，例如：./clean_ports.sh 53 80 443
# 支持 dry-run 模式：通过 --dry-run 查看将被终止的目标，但不实际执行
# ------------------------------------------------------------------------------

set -e

# ========== 参数处理 ==========
PORTS=""
DRYRUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRYRUN=1
      ;;
    *)
      PORTS="$PORTS $arg"
      ;;
  esac
done

if [ -z "$PORTS" ]; then
  echo "❗ 用法：$0 [--dry-run] <port1> <port2> ..."
  exit 1
fi

[ "$DRYRUN" -eq 1 ] && echo "🧪 Dry Run 模式开启，仅展示将被终止的目标，不执行操作。"

TMP_CONTAINER=$(mktemp)
TMP_PROCESS=$(mktemp)

echo "🔍 正在检查端口占用情况：$PORTS"

# ========== 检查容器监听端口 ==========
for PORT in $PORTS; do
  docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep ":$PORT->" | while read ID NAME PORTMAP; do
    echo "$PORT $ID $NAME" >> "$TMP_CONTAINER"
  done

  # 检查进程占用
  netstat -tulpn 2>/dev/null | grep ":$PORT" | while read -r line; do
    proto=$(echo "$line" | awk '{print $1}')
    pid_info=$(echo "$line" | awk '{print $NF}')
    echo "$pid_info" | grep -qE '^[0-9]+/[^[:space:]]+$' || continue
    pid=$(echo "$pid_info" | cut -d'/' -f1)
    name=$(echo "$pid_info" | cut -d'/' -f2)
    [ "$name" = "docker-proxy" ] && docker ps | grep -q "$PORT" && continue
    echo "$PORT $proto $pid $name" >> "$TMP_PROCESS"
  done

done

# ========== 显示待释放项 ==========
[ -s "$TMP_CONTAINER" ] && {
  echo "📦 以下容器监听端口："
  awk '{printf "  → 容器 %s (%s) 占用端口 %s\n", $3, $2, $1}' "$TMP_CONTAINER"
}

[ -s "$TMP_PROCESS" ] && {
  echo "🧩 以下进程监听端口："
  awk '{printf "  → [%s] 端口 %s - PID=%s - 进程名=%s\n", $2, $1, $3, $4}' "$TMP_PROCESS"
}

if [ ! -s "$TMP_CONTAINER" ] && [ ! -s "$TMP_PROCESS" ]; then
  echo "✅ 无端口占用，退出。"
  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
  exit 0
fi

if [ "$DRYRUN" -eq 1 ]; then
  echo "✅ Dry Run 结束，无操作执行。"
  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
  exit 0
fi

# ========== 用户确认 ==========
echo -n "⚠️ 是否终止上述容器和进程？[y/N]: "
read CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "❎ 已取消操作。"
  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
  exit 0
fi

# ========== 执行终止操作 ==========
[ -s "$TMP_CONTAINER" ] && sort -u "$TMP_CONTAINER" | awk '{print $2}' | sort -u | while read ID; do
  echo "🛑 停止容器 $ID ..."
  docker stop "$ID" > /dev/null 2>&1 && echo "     ✅ 已停止" || echo "     ❌ 停止失败"
  echo "🗑️ 删除容器 $ID ..."
  docker rm "$ID" > /dev/null 2>&1 && echo "     ✅ 已删除" || echo "     ❌ 删除失败"

done

[ -s "$TMP_PROCESS" ] && awk '{print $3}' "$TMP_PROCESS" | sort -u | while read PID; do
  echo "🔪 终止进程 PID=$PID ..."
  kill "$PID" 2>/dev/null && echo "     ✅ 已终止 (TERM)" || {
    kill -9 "$PID" 2>/dev/null && echo "     ⚠️ 已强制终止 (KILL)" || echo "     ❌ 无法终止进程 PID=$PID"
  }
done

rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
echo "✅ 清理完成。"
exit 0
