#!/bin/sh

# ------------------------------------------------------------------------------
# clean_ports.sh
# 功能：检测并释放指定端口被占用的容器或进程资源（支持 dry-run 查看模式）
# 作者：Andy Da（ChatGPT 协助）
# 更新时间：2025-06-22
# ------------------------------------------------------------------------------

set -e  # 遇到错误时立即退出脚本

# ======================= 参数初始化 =======================
DRYRUN=0            # 是否 dry-run 模式，默认关闭
PORTS=""            # 存储用户指定的端口列表

# ======================= 参数解析 ==========================
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRYRUN=1  # 启用 dry-run 模式
      ;;
    *)
      PORTS="$PORTS $arg"  # 添加端口到检查列表
      ;;
  esac
done

# 若未指定任何端口，则提示用户并退出
if [ -z "$PORTS" ]; then
  echo "❗ 请指定一个或多个要检查的端口，例如：./clean_ports.sh 53 80"
  exit 1
fi

# ======================= 创建临时文件 =======================
TMP_CONTAINER=$(mktemp)  # 存储容器监听端口信息
TMP_PROCESS=$(mktemp)    # 存储进程监听端口信息

# ======================= 开始检测 ===========================
echo "🔍 正在检查端口占用情况：$PORTS"
echo ""

# ---------- 检查容器是否监听指定端口 ----------
for PORT in $PORTS; do
  docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | while read ID NAME PORTMAP; do
    echo "$PORTMAP" | grep -qE "0\.0\.0\.0:$PORT->|:$PORT->" || continue
    echo "$PORT $ID $NAME" >> "$TMP_CONTAINER"
  done
done

# ---------- 检查系统进程是否监听指定端口 ----------
for PORT in $PORTS; do
  netstat -tulpn 2>/dev/null | grep ":$PORT" | while read -r line; do
    proto=$(echo "$line" | awk '{print $1}')         # 协议类型
    pid_info=$(echo "$line" | awk '{print $NF}')     # PID/程序名

    # 跳过没有 PID 信息的记录（如 PID="-"）
    echo "$pid_info" | grep -qE '^[0-9]+/[^[:space:]]+$' || continue

    pid=$(echo "$pid_info" | cut -d'/' -f1)
    name=$(echo "$pid_info" | cut -d'/' -f2)

    # 忽略 docker-proxy 占用的端口（由容器占用已记录）
    [ "$name" = "docker-proxy" ] && docker ps | grep -q "$PORT" && continue

    echo "$PORT $proto $pid $name" >> "$TMP_PROCESS"
  done
done

# ======================= 显示检测结果 =======================
if [ -s "$TMP_CONTAINER" ]; then
  echo "📦 以下容器监听了目标端口："
  awk '{printf "  🛑 容器 %s (%s) 占用端口 %s\n", $3, $2, $1}' "$TMP_CONTAINER"
else
  echo "📦 无容器监听目标端口。"
fi

echo ""

if [ -s "$TMP_PROCESS" ]; then
  echo "🧩 以下非容器进程占用了端口："
  awk '{printf "  🔧 [%s] PID=%s (%s) 占用端口 %s\n", $2, $3, $4, $1}' "$TMP_PROCESS"
else
  echo "🧩 无非容器进程监听目标端口。"
fi

# ======================= 若无占用直接退出 ===================
if [ ! -s "$TMP_CONTAINER" ] && [ ! -s "$TMP_PROCESS" ]; then
  echo ""
  echo "✅ 没有发现任何需要释放的端口占用，任务结束。"
  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
  exit 0
fi

# ======================= dry-run 模式处理 ===================
if [ "$DRYRUN" -eq 1 ]; then
  echo ""
  echo "✅ Dry Run 模式结束，未执行任何终止操作。"
  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
  exit 0
fi

# ======================= 用户确认释放动作 ===================
echo ""
echo "📝 以下对象将被释放："
[ -s "$TMP_CONTAINER" ] && awk '{printf "  ➤ 容器 %s (%s) 监听端口 %s\n", $3, $2, $1}' "$TMP_CONTAINER"
[ -s "$TMP_PROCESS" ] && awk '{printf "  ➤ [%s] 端口 %s - PID=%s - 类型=%s - 进程名=%s\n", $2, $1, $3, $2, $4}' "$TMP_PROCESS"

echo ""
echo -n "⚠️ 是否终止这些容器 / 进程？[y/N]: "
read CONFIRM < /dev/tty

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "❎ 已取消操作。"
  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
  exit 0
fi

# ======================= 执行释放 ===========================
echo ""
echo "🛠️  正在执行释放操作..."

# ---------- 停止并删除容器 ----------
if [ -s "$TMP_CONTAINER" ]; then
  sort -u "$TMP_CONTAINER" | awk '{print $2}' | sort -u | while read ID; do
    echo "  🛑 停止容器 $ID ..."
    if docker stop "$ID" > /dev/null 2>&1; then
      echo "     ✅ 已停止"
    else
      echo "     ❌ 停止失败"
    fi

    echo "  ❌ 删除容器 $ID ..."
    if docker rm "$ID" > /dev/null 2>&1; then
      echo "     ✅ 已删除"
    else
      echo "     ❌ 删除失败"
    fi
  done
fi

# ---------- 终止系统进程 ----------
if [ -s "$TMP_PROCESS" ]; then
  awk '{print $3}' "$TMP_PROCESS" | sort -u | while read PID; do
    echo "  🔪 终止进程 PID=$PID ..."
    if kill "$PID" 2>/dev/null; then
      echo "     ✅ 已终止"
    elif kill -9 "$PID" 2>/dev/null; then
      echo "     ⚠️ 已强制终止 (KILL)"
    else
      echo "     ❌ 无法终止进程 PID=$PID"
    fi
  done
fi

# ======================= 清理临时文件 ======================
echo ""
echo "✅ 所有对象已处理完成。"
rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
