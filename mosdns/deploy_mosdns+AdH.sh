#!/bin/sh
# ------------------------------------------------------------------------------
# Script Name: deploy-mosdns+AdH.sh
# Purpose: 一键部署 MosDNS + AdGuardHome (国内/国外) 的容器服务
# 目标：提供稳定、分流、安全的本地 DNS 系统
# 环境：Alpine Linux / OpenRC / Docker
# ------------------------------------------------------------------------------
# 作者：Andy Da（ChatGPT 协助）
# 更新时间：2025-06-21
# ------------------------------------------------------------------------------

set -e  # 遇到错误立即退出整个脚本执行

# ======================== 目录变量定义 ========================
MOSDNS_DIR="$HOME/mosdns"        # MosDNS 安装根目录
ADH_CN_DIR="$HOME/AdH_CN"        # 国内 AdGuardHome 配置目录
ADH_GFW_DIR="$HOME/AdH_GFW"      # 国外 AdGuardHome 配置目录
CRONTAB_FILE="/etc/crontabs/root"  # 系统 root 用户的定时任务配置文件

# ======================== 步骤 7：清理环境函数 ========================
# 功能：释放端口（53/54/55）占用的容器和进程，清理旧配置目录
cleanup_environment() {
  PORTS="53 54 55"
  TMP_CONTAINER=$(mktemp)  # 暂存容器监听端口信息
  TMP_PROCESS=$(mktemp)    # 暂存进程监听端口信息

  echo "[7/14] 清理旧容器并释放端口占用..."

  # 检查容器是否监听指定端口
  for PORT in $PORTS; do
    docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep ":$PORT->" | while read ID NAME PORTMAP; do
      echo "$PORT $ID $NAME" >> "$TMP_CONTAINER"
    done
  done

  # 检查普通进程是否监听指定端口（排除 docker-proxy）
  for PORT in $PORTS; do
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

  # 如果无占用则跳出
  if [ ! -s "$TMP_CONTAINER" ] && [ ! -s "$TMP_PROCESS" ]; then
    echo "✅ 没有发现任何需要释放的端口占用。"
  else
    echo "📝 以下对象将被释放："
    [ -s "$TMP_CONTAINER" ] && awk '{printf "  → 容器 %s (%s) 监听端口 %s\n", $3, $2, $1}' "$TMP_CONTAINER"
    [ -s "$TMP_PROCESS" ] && awk '{printf "  → [%s] 端口 %s - PID=%s - 类型=%s - 进程名=%s\n", $2, $1, $3, $2, $4}' "$TMP_PROCESS"

    echo ""
    # 非交互终端默认取消
    if [ -t 0 ]; then
      echo -n "⚠️ 是否终止这些容器 / 进程？[y/N]: "
      read CONFIRM
    else
      echo "⚠️ 非交互模式下默认取消操作。"
      CONFIRM="n"
    fi

    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
      echo "❎ 已取消操作。"
      rm -f "$TMP_CONTAINER" "$TMP_PROCESS"
      exit 0
    fi

    echo "🛠️ 正在执行释放操作..."

    # 停止并删除容器
    [ -s "$TMP_CONTAINER" ] && sort -u "$TMP_CONTAINER" | awk '{print $2}' | sort -u | while read ID; do
      echo "  🛑 停止容器 $ID ..."
      docker stop "$ID" > /dev/null 2>&1 && echo "     ✅ 已停止" || echo "     ❌ 停止失败"
      echo "  ❌ 删除容器 $ID ..."
      docker rm "$ID" > /dev/null 2>&1 && echo "     ✅ 已删除" || echo "     ❌ 删除失败"
    done

    # 优雅终止进程，失败则强杀
    [ -s "$TMP_PROCESS" ] && awk '{print $3}' "$TMP_PROCESS" | sort -u | while read PID; do
      echo "  🔪 终止进程 PID=$PID ..."
      kill "$PID" 2>/dev/null && echo "     ✅ 已终止 (TERM)" || {
        kill -9 "$PID" 2>/dev/null && echo "     ⚠️ 已强制终止 (KILL)" || echo "     ❌ 无法终止进程 PID=$PID"
      }
    done
  fi

  rm -f "$TMP_CONTAINER" "$TMP_PROCESS"

  # 清理旧目录结构
  echo ""
  echo "🧹 清理配置目录..."
  rm -rf "$MOSDNS_DIR" "$ADH_CN_DIR" "$ADH_GFW_DIR"
  mkdir -p "$MOSDNS_DIR"
  echo "✅ 环境清理完成。"
}

# 后续步骤注释已在脚本中，每一步都已用 echo 明确说明其作用。
# 若需要，我可将每一步的逻辑（例如 curl 下载的用途、Docker Compose 配置说明等）逐条细化。
