#!/bin/sh

# ==============================================================================
# CFST Cron 自动执行脚本【多地区分批测速 + 全局 Top 10 CFST 策略组版】
# ==============================================================================
#
# 本脚本职责：
#   1. 拉取公开仓库 cfst 最新配置与私人仓库 dayunliang/private_config；
#   2. 按 CFST_COLOS 列表依次针对 新加坡(SIN) / 美国(LAX) / 德国(FRA) / 荷兰(AMS) 独立测速；
#   3. 每个地区提取前 5 个可用高速节点，合并生成统一的 data/result.csv；
#   4. 将合并结果写入私人仓库中的 Personal_Use_ALL.yaml（新节点优先、按 server:port 去重）；
#   5. 按下载速度降序提取全局前 10 个节点，在 proxy-groups 顶部自动维护独立的 CFST 策略组；
#   6. 提交并 push 修改后的 Personal_Use_ALL.yaml，通过 DingTalk 发送单次汇总报告。
#
# ==============================================================================

set -eu

# ==============================================================================
# 1. 基础路径与仓库变量
# ==============================================================================

# CFST 工作目录
WORK_DIR="/root/cfst"

# CFST 数据与临时文件目录
DATA_DIR="$WORK_DIR/data"

# Docker Compose 配置文件路径
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"

# 公开仓库远程名
PUBLIC_GIT_REMOTE="origin"

# 公开仓库分支名
PUBLIC_GIT_BRANCH="main"

# 私人仓库本地目录
PRIVATE_REPO_DIR="/root/private_config"

# 私人仓库 SSH 地址
PRIVATE_REPO_SSH="git@github.com:dayunliang/private_config.git"

# 私人仓库远程名
PRIVATE_GIT_REMOTE="origin"

# 私人仓库分支名
PRIVATE_GIT_BRANCH="main"

# OpenClash 配置文件在私人仓库中的相对路径
PRIVATE_TARGET_RELATIVE_PATH="Lean/files/etc/openclash/config/Personal_Use_ALL.yaml"

# OpenClash 配置文件完整路径
PRIVATE_TARGET_FILE="$PRIVATE_REPO_DIR/$PRIVATE_TARGET_RELATIVE_PATH"

# Git 提交用户名
GIT_USER_NAME="alpine-cron"

# Git 提交邮箱
GIT_USER_EMAIL="cron@homelab.local"

# 当天日期
TODAY="$(date '+%Y-%m-%d')"

# 任务开始时间（人类可读格式）
START_TIME="$(date '+%Y-%m-%d %H:%M')"

# 任务开始时间戳（用于计算总耗时）
START_EPOCH="$(date '+%s')"

# Git commit 使用的时间戳
NOW_TIME="$START_TIME"

# 合并后的最终测速结果 CSV 路径
RESULT_CSV="$DATA_DIR/result.csv"

# 钉钉更新报告 Markdown 路径
REPORT_FILE="$DATA_DIR/openclash_update_report.md"

# 完整运行日志路径
FULL_LOG_FILE="$DATA_DIR/cron-cfst-full.log"

# ==============================================================================
# 1.1 多地区 CFST 测速与策略组变量
# ==============================================================================

# docker-compose.yml 中的服务名称
CFST_SERVICE_NAME="cloudflare-speedtest"

# 运行时的容器名称
CFST_CONTAINER_NAME="cfst"

# 需要依次测速的 Cloudflare 机房三字码列表（空格分隔：新加坡 / 美国 / 德国 / 荷兰）
CFST_COLOS="SIN LAX FRA AMS"

# 每个地区下载测速并保留的前 N 个节点数
CFST_PER_COLO_COUNT="5"

# 每个地区在 Personal_Use_ALL.yaml 中最终保留的最大节点数
MAX_NODES_PER_REGION="5"

# 自动维护的独立策略组名称
CFST_GROUP_NAME="CFST"

# 独立策略组类型（url-test 自动选最快 / select 手动切换）
CFST_GROUP_TYPE="url-test"

# 独立策略组收录的全局最快节点数量
CFST_GROUP_TOP_N="10"

# CFST 输入 IP 段文件（容器内相对路径）
CFST_IP_FILE="data/ip.txt"

# CFST 延迟测速并发数
CFST_THREADS="150"

# CFST 单 IP 延迟测速次数
CFST_PING_TIMES="4"

# CFST 单 IP 下载测速时长（秒）
CFST_DOWNLOAD_TIME="5"

# CFST 平均延迟上限（毫秒）
CFST_MAX_LATENCY="350"

# CFST 下载速度下限（MB/s，0 表示不限）
CFST_MIN_SPEED="0"

# CFST 测速文件地址（R2 存储桶）
CFST_TEST_URL="https://speedtest.b-gfw.cf-ip.cfd/300mb.bin"

# 单个地区测速容器的最大等待时间（秒，1200 秒 = 20 分钟）
CFST_MAX_WAIT_SECONDS=1200

# 监控容器状态的轮询间隔（秒）
CFST_WAIT_STEP_SECONDS=10

# ==============================================================================
# 1.2 OpenClash / VLESS 节点模板变量
# ==============================================================================

# VLESS 节点端口
VLESS_PORT="443"

# VLESS UUID
VLESS_UUID="bc398b21-15f3-484e-83c1-d99f16dc6c4a"

# TLS SNI 域名
VLESS_SERVERNAME="b-gfw.cf-ip.cfd"

# WebSocket Host 头
VLESS_HOST="b-gfw.cf-ip.cfd"

# WebSocket 路径
VLESS_WS_PATH="/?ed=2560"

# TLS 客户端指纹
VLESS_CLIENT_FINGERPRINT="chrome"

# ==============================================================================
# 1.3 DingTalk 配置变量
# ==============================================================================

# 钉钉应用 AppKey
DING_APP_KEY="dingecswocgwfsntk2v2"

# 钉钉应用 AppSecret
DING_APP_SECRET="pMiPruv-gJw6un6138ELUzGEBCyhPGk4pe3WZiEdJPPcJQlmi8JkK5Zh_uyvdHM_"

# 钉钉接收人 UserID
DING_USER_ID="manager3729"

# ==============================================================================
# 2. DingTalk 通知函数
# ==============================================================================

json_escape_for_dingtalk() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json, sys; print(json.dumps(sys.stdin.read(), ensure_ascii=False)[1:-1])'
        return 0
    fi

    sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}'
}

notify_dingtalk_private_markdown() {
    DING_TITLE="$1"
    DING_TEXT="$2"

    if [ -z "$DING_APP_KEY" ] || [ -z "$DING_APP_SECRET" ] || [ -z "$DING_USER_ID" ]; then
        echo "未完整配置 DingTalk 变量，跳过 DingTalk 私聊通知。"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "DingTalk 通知跳过：系统未安装 curl。"
        return 0
    fi

    TOKEN_PAYLOAD="$(cat <<TOKEN_EOF
{
  "appKey": "$DING_APP_KEY",
  "appSecret": "$DING_APP_SECRET"
}
TOKEN_EOF
)"

    TOKEN_RES="$(curl -sS -X POST "https://api.dingtalk.com/v1.0/oauth2/accessToken" -H "Content-Type: application/json" -d "$TOKEN_PAYLOAD" || true)"

    ACCESS_TOKEN="$(printf '%s' "$TOKEN_RES" | sed -n 's/.*"accessToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

    if [ -z "$ACCESS_TOKEN" ]; then
        echo "警告：DingTalk accessToken 获取失败，跳过推送。"
        echo "DingTalk token 返回：$TOKEN_RES"
        return 0
    fi

    DING_TITLE_JSON="$(printf '%s' "$DING_TITLE" | json_escape_for_dingtalk)"
    DING_TEXT_JSON="$(printf '%s' "$DING_TEXT" | json_escape_for_dingtalk)"

    MSG_PARAM="{\"title\":\"$DING_TITLE_JSON\",\"text\":\"$DING_TEXT_JSON\"}"
    MSG_PARAM_JSON="$(printf '%s' "$MSG_PARAM" | json_escape_for_dingtalk)"

    SEND_PAYLOAD="$(cat <<SEND_EOF
{
  "robotCode": "$DING_APP_KEY",
  "userIds": ["$DING_USER_ID"],
  "msgKey": "sampleMarkdown",
  "msgParam": "$MSG_PARAM_JSON"
}
SEND_EOF
)"

    SEND_RES="$(curl -sS -X POST "https://api.dingtalk.com/v1.0/robot/oToMessages/batchSend" -H "x-acs-dingtalk-access-token: $ACCESS_TOKEN" -H "Content-Type: application/json" -d "$SEND_PAYLOAD" || true)"

    echo "DingTalk 返回：$SEND_RES"
    return 0
}

# ==============================================================================
# 2.1 终端输出格式函数
# ==============================================================================

print_line() {
    printf '%s\n' '────────────────────────────────────────'
}

print_section() {
    printf '\n'
    print_line
    printf '▶ %s\n' "$1"
    print_line
}

print_ok() {
    printf '✔ %s\n' "$1"
}

print_warn() {
    printf '⚠ %s\n' "$1"
}

print_error() {
    printf '✘ %s\n' "$1"
}

run_quiet() {
    STEP_NAME="$1"
    shift

    printf '• %s ... ' "$STEP_NAME"

    if "$@" >> "$FULL_LOG_FILE" 2>&1; then
        printf 'OK\n'
        return 0
    fi

    printf 'FAILED\n'
    print_error "$STEP_NAME 失败，完整日志：$FULL_LOG_FILE"
    return 1
}

format_duration_seconds() {
    TOTAL_SECONDS="$1"

    if [ -z "$TOTAL_SECONDS" ]; then
        TOTAL_SECONDS=0
    fi

    HOURS=$((TOTAL_SECONDS / 3600))
    MINUTES=$(((TOTAL_SECONDS % 3600) / 60))
    SECONDS=$((TOTAL_SECONDS % 60))

    if [ "$HOURS" -gt 0 ]; then
        printf '%02d:%02d:%02d' "$HOURS" "$MINUTES" "$SECONDS"
    else
        printf '%02d:%02d' "$MINUTES" "$SECONDS"
    fi
}

print_cfst_csv_summary() {
    if [ ! -s "$RESULT_CSV" ]; then
        print_warn "result.csv 不存在，无法显示测速摘要。"
        return 0
    fi

    python3 - "$RESULT_CSV" <<'PY_SUMMARY_EOF'
import csv
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = []

with path.open('r', encoding='utf-8-sig', newline='') as f:
    for row in csv.reader(f):
        if not row or len(row) < 7:
            continue
        ip = (row[0] or '').strip()
        if not re.match(r'^(\d{1,3}\.){3}\d{1,3}$', ip) and ':' not in ip:
            continue
        try:
            speed = float((row[5] or '0').strip())
        except ValueError:
            speed = 0.0
        if speed <= 0:
            continue
        latency = (row[4] or '').strip()
        code = (row[6] or '').strip().upper()
        rows.append((ip, latency, speed, code))

rows.sort(key=lambda x: x[2], reverse=True)

print('')
print(f'合并测速结果（共 {len(rows)} 个有效节点，按速率降序展示前 20）：')

if not rows:
    print('未解析到有效测速节点。')
else:
    for idx, (ip, latency, speed, code) in enumerate(rows[:20], start=1):
        print(f'{idx}. {ip} / {speed:.2f} MB/s / {latency} ms / {code}')
PY_SUMMARY_EOF
}

# ==============================================================================
# 3. 进入 CFST 工作目录并拉取最新公开配置
# ==============================================================================

cd "$WORK_DIR" || {
    echo "错误：无法进入 CFST 工作目录：$WORK_DIR"
    exit 1
}

mkdir -p "$DATA_DIR"
: > "$FULL_LOG_FILE"
rm -f "$DATA_DIR/cfst-docker-last.log"

PUBLIC_REPO_ROOT="$(git rev-parse --show-toplevel)"

print_section "CFST Cron 任务启动"
printf '开始时间：%s\n' "$START_TIME"
printf '工作目录：%s\n' "$WORK_DIR"
printf '公开仓库：%s\n' "$PUBLIC_REPO_ROOT"
printf '目标地区：%s（每地区取前 %s 个）\n' "$CFST_COLOS" "$CFST_PER_COLO_COUNT"
printf '聚合分组：%s（type=%s，全局 Top %s）\n' "$CFST_GROUP_NAME" "$CFST_GROUP_TYPE" "$CFST_GROUP_TOP_N"
printf '完整日志：%s\n' "$FULL_LOG_FILE"

git -C "$PUBLIC_REPO_ROOT" config user.name "$GIT_USER_NAME" >> "$FULL_LOG_FILE" 2>&1
git -C "$PUBLIC_REPO_ROOT" config user.email "$GIT_USER_EMAIL" >> "$FULL_LOG_FILE" 2>&1

print_section "同步仓库"
run_quiet "拉取公开仓库配置" git -C "$PUBLIC_REPO_ROOT" fetch "$PUBLIC_GIT_REMOTE" "$PUBLIC_GIT_BRANCH"
run_quiet "合并公开仓库配置" git -C "$PUBLIC_REPO_ROOT" pull --rebase --autostash "$PUBLIC_GIT_REMOTE" "$PUBLIC_GIT_BRANCH"

if [ ! -s "$COMPOSE_FILE" ]; then
    echo "错误：$COMPOSE_FILE 不存在或为空。"
    exit 1
fi

# ==============================================================================
# 4. 初始化 / 更新私人仓库
# ==============================================================================

if [ ! -d "$PRIVATE_REPO_DIR/.git" ]; then
    print_warn "私人仓库不存在，开始 clone：$PRIVATE_REPO_DIR"
    rm -rf "$PRIVATE_REPO_DIR"
    run_quiet "clone 私人仓库" git clone "$PRIVATE_REPO_SSH" "$PRIVATE_REPO_DIR"
fi

git -C "$PRIVATE_REPO_DIR" config user.name "$GIT_USER_NAME" >> "$FULL_LOG_FILE" 2>&1
git -C "$PRIVATE_REPO_DIR" config user.email "$GIT_USER_EMAIL" >> "$FULL_LOG_FILE" 2>&1

run_quiet "拉取私人仓库" git -C "$PRIVATE_REPO_DIR" fetch "$PRIVATE_GIT_REMOTE" "$PRIVATE_GIT_BRANCH"
run_quiet "合并私人仓库" git -C "$PRIVATE_REPO_DIR" pull --rebase --autostash "$PRIVATE_GIT_REMOTE" "$PRIVATE_GIT_BRANCH"

if [ ! -s "$PRIVATE_TARGET_FILE" ]; then
    echo "错误：目标 OpenClash 配置不存在或为空：$PRIVATE_TARGET_FILE"
    exit 1
fi

# ==============================================================================
# 5. 按地区循环运行 CFST 测速，并合并生成 result.csv
# ==============================================================================

rm -f "$RESULT_CSV"
rm -f "$REPORT_FILE"
rm -f "$DATA_DIR"/result_*.csv

print_section "按地区运行 CFST 测速"

run_quiet "清理旧 CFST 容器与网络" docker compose down --remove-orphans

HEADER_WRITTEN=0

for COLO in $CFST_COLOS; do
    COLO_CSV_REL="data/result_${COLO}.csv"
    COLO_CSV_ABS="$DATA_DIR/result_${COLO}.csv"
    rm -f "$COLO_CSV_ABS"

    docker rm -f "$CFST_CONTAINER_NAME" >> "$FULL_LOG_FILE" 2>&1 || true

    printf '\n>>> 开始测速地区：%s（目标保留前 %s 个）\n' "$COLO" "$CFST_PER_COLO_COUNT"

    if ! docker compose run -d --name "$CFST_CONTAINER_NAME" "$CFST_SERVICE_NAME" -f "$CFST_IP_FILE" -httping -httping-code 200 -cfcolo "$COLO" -n "$CFST_THREADS" -t "$CFST_PING_TIMES" -dn "$CFST_PER_COLO_COUNT" -dt "$CFST_DOWNLOAD_TIME" -tl "$CFST_MAX_LATENCY" -sl "$CFST_MIN_SPEED" -p "$CFST_PER_COLO_COUNT" -url "$CFST_TEST_URL" -o "$COLO_CSV_REL" >> "$FULL_LOG_FILE" 2>&1; then
        print_warn "地区 $COLO 启动 CFST 容器失败，跳过该地区。"
        continue
    fi

    CFST_WAITED_SECONDS=0
    CFST_TIMEOUT_HIT=0
    CFST_EXIT_CODE="unknown"

    while docker ps --format '{{.Names}}' | grep -qx "$CFST_CONTAINER_NAME"; do
        if [ "$CFST_WAITED_SECONDS" -ge "$CFST_MAX_WAIT_SECONDS" ]; then
            print_warn "地区 $COLO 容器运行超过 $CFST_MAX_WAIT_SECONDS 秒，强制停止。"
            CFST_TIMEOUT_HIT=1
            {
                echo
                echo "==================== CFST Docker Log [$COLO - TIMEOUT] ===================="
                docker logs --tail=200 "$CFST_CONTAINER_NAME" 2>&1 || true
                echo "================== End CFST Docker Log [$COLO - TIMEOUT] =================="
                echo
            } >> "$FULL_LOG_FILE"
            docker stop "$CFST_CONTAINER_NAME" >> "$FULL_LOG_FILE" 2>&1 || true
            break
        fi

        sleep "$CFST_WAIT_STEP_SECONDS"
        CFST_WAITED_SECONDS=$((CFST_WAITED_SECONDS + CFST_WAIT_STEP_SECONDS))
    done

    if docker ps -a --format '{{.Names}}' | grep -qx "$CFST_CONTAINER_NAME"; then
        CFST_EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$CFST_CONTAINER_NAME" 2>/dev/null || printf 'unknown')"
        {
            echo
            echo "==================== CFST Docker Log [$COLO] ===================="
            docker logs --tail=200 "$CFST_CONTAINER_NAME" 2>&1 || true
            echo "================== End CFST Docker Log [$COLO] =================="
            echo
        } >> "$FULL_LOG_FILE"
        docker rm -f "$CFST_CONTAINER_NAME" >> "$FULL_LOG_FILE" 2>&1 || true
    fi

    printf '地区 %s 完成：耗时 %s 秒 | 退出码 %s | 超时 %s\n' "$COLO" "$CFST_WAITED_SECONDS" "$CFST_EXIT_CODE" "$CFST_TIMEOUT_HIT"

    if [ -s "$COLO_CSV_ABS" ]; then
        if [ "$HEADER_WRITTEN" -eq 0 ]; then
            cat "$COLO_CSV_ABS" > "$RESULT_CSV"
            HEADER_WRITTEN=1
        else
            tail -n +2 "$COLO_CSV_ABS" >> "$RESULT_CSV"
        fi
        print_ok "地区 $COLO 测速结果已合并。"
    else
        print_warn "地区 $COLO 未生成有效 CSV，跳过合并。"
    fi
done

run_quiet "清理本次 CFST 临时网络" docker compose down --remove-orphans

if [ ! -s "$RESULT_CSV" ]; then
    print_error "所有地区测速完成后均未生成有效 result.csv：$RESULT_CSV"
    exit 1
fi

print_cfst_csv_summary

# ==============================================================================
# 6. 合并 result.csv 到 OpenClash Personal_Use_ALL.yaml 并更新 CFST 策略组
# ==============================================================================

print_section "合并 OpenClash 节点与 CFST 策略组"

python3 - "$RESULT_CSV" "$PRIVATE_TARGET_FILE" "$REPORT_FILE" "$NOW_TIME" "$VLESS_PORT" "$VLESS_UUID" "$VLESS_SERVERNAME" "$VLESS_HOST" "$VLESS_WS_PATH" "$VLESS_CLIENT_FINGERPRINT" "$MAX_NODES_PER_REGION" "$CFST_GROUP_NAME" "$CFST_GROUP_TYPE" "$CFST_GROUP_TOP_N" <<'PYTHON_EOF'
import csv
import re
import sys
from pathlib import Path

result_csv = Path(sys.argv[1])
target_file = Path(sys.argv[2])
report_file = Path(sys.argv[3])
now_time = sys.argv[4]

vless_port = sys.argv[5]
vless_uuid = sys.argv[6]
vless_servername = sys.argv[7]
vless_host = sys.argv[8]
vless_ws_path = sys.argv[9]
vless_fingerprint = sys.argv[10]
max_nodes_per_region = int(sys.argv[11])
cfst_group_name = sys.argv[12]
cfst_group_type = sys.argv[13]
cfst_group_top_n = int(sys.argv[14])

REGION_ORDER = [
    "HKG", "SIN", "JPN", "KOR", "TWN", "USA", "GBR", "DEU", "FRA", "NLD", "AUS", "CAN", "OTHER"
]

REGION_INFO = {
    "HKG": ("香港", "Hong Kong"),
    "SIN": ("新加坡", "Singapore"),
    "JPN": ("日本", "Japan"),
    "KOR": ("韩国", "Korea"),
    "TWN": ("台湾", "Taiwan"),
    "USA": ("美国", "United States"),
    "GBR": ("英国", "United Kingdom"),
    "DEU": ("德国", "Germany"),
    "FRA": ("法国", "France"),
    "NLD": ("荷兰", "Netherlands"),
    "AUS": ("澳大利亚", "Australia"),
    "CAN": ("加拿大", "Canada"),
    "OTHER": ("其它", "Other"),
}

REGION_FLAG = {
    "HKG": "🇭🇰",
    "SIN": "🇸🇬",
    "JPN": "🇯🇵",
    "KOR": "🇰🇷",
    "TWN": "🇹🇼",
    "USA": "🇺🇸",
    "GBR": "🇬🇧",
    "DEU": "🇩🇪",
    "FRA": "🇫🇷",
    "NLD": "🇳🇱",
    "AUS": "🇦🇺",
    "CAN": "🇨🇦",
    "OTHER": "🏳️",
}

CODE_TO_REGION = {
    "HKG": "HKG",
    "SIN": "SIN",
    "NRT": "JPN", "HND": "JPN", "KIX": "JPN", "FUK": "JPN", "OKA": "JPN",
    "ICN": "KOR", "GMP": "KOR",
    "TPE": "TWN", "KHH": "TWN",
    "SJC": "USA", "LAX": "USA", "SEA": "USA", "IAD": "USA", "ORD": "USA", "DFW": "USA", "MIA": "USA", "EWR": "USA", "JFK": "USA", "ATL": "USA", "DEN": "USA", "PHX": "USA", "LAS": "USA",
    "LHR": "GBR", "MAN": "GBR",
    "FRA": "DEU",
    "CDG": "FRA",
    "AMS": "NLD",
    "SYD": "AUS", "MEL": "AUS",
    "YYZ": "CAN", "YVR": "CAN",
}

CF_NAME_RE = re.compile(r"^- name:\s*CF-优选-(?P<region>.+?)\s+\d+\s*$")
SERVER_RE = re.compile(r"^\s*server:\s*(?P<server>.+?)\s*$")
PORT_RE = re.compile(r"^\s*port:\s*(?P<port>\d+)\s*$")
CF_SECTION_HEADER_RE = re.compile(r"^#\s*(?P<region>.+?)优选\s*\((?P<en>.+?)\)\s*$")
CFST_META_RE = re.compile(r"^#\s*CFST-META:\s*(?P<meta>.*)$")

CN_TO_REGION = {cn: key for key, (cn, _en) in REGION_INFO.items()}


def normalize_region_from_code(code: str) -> str:
    code = (code or "").strip().upper()
    return CODE_TO_REGION.get(code, "OTHER")


def normalize_region_from_name(region_name: str) -> str:
    region_name = (region_name or "").strip()
    return CN_TO_REGION.get(region_name, "OTHER")


def parse_cfst_meta(line: str) -> dict:
    m = CFST_META_RE.match((line or "").strip())
    if not m:
        return {}

    meta_text = m.group("meta")
    meta = {}
    for part in meta_text.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        key, value = part.split("=", 1)
        meta[key.strip()] = value.strip()
    return meta


def strip_unit(value: str, unit: str) -> str:
    value = (value or "").strip()
    if not value:
        return "N/A"
    if value.upper() == "N/A":
        return "N/A"
    if value.lower().endswith(unit.lower()):
        return value[: -len(unit)].strip()
    return value


def format_speed(value) -> str:
    if value is None:
        return "N/A"
    if isinstance(value, (int, float)):
        return f"{value:.2f} MB/s"
    text = str(value).strip()
    if not text or text.upper() == "N/A":
        return "N/A"
    if text.lower().endswith("mb/s"):
        return text
    try:
        return f"{float(text):.2f} MB/s"
    except ValueError:
        return text


def format_latency(value) -> str:
    if value is None:
        return "N/A"
    if isinstance(value, (int, float)):
        return f"{value:.2f} ms"
    text = str(value).strip()
    if not text or text.upper() == "N/A":
        return "N/A"
    if text.lower().endswith("ms"):
        return text
    try:
        return f"{float(text):.2f} ms"
    except ValueError:
        return text


def read_existing_cf_nodes(text: str):
    lines = text.splitlines()
    nodes = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = CF_NAME_RE.match(line)
        if not m:
            i += 1
            continue

        meta = {}
        if i > 0:
            meta = parse_cfst_meta(lines[i - 1])

        block = [line]
        j = i + 1
        while j < len(lines):
            if lines[j].startswith("- name: ") or re.match(r"^[A-Za-z0-9_-]+:\s*$", lines[j]):
                break
            block.append(lines[j])
            j += 1

        region_key = normalize_region_from_name(m.group("region"))
        server = ""
        port = vless_port

        for bline in block:
            sm = SERVER_RE.match(bline)
            if sm:
                server = sm.group("server").strip().strip('"').strip("'")
            pm = PORT_RE.match(bline)
            if pm:
                port = pm.group("port").strip()

        if server:
            nodes.append({
                "region": region_key,
                "server": server,
                "port": port,
                "source": "old",
                "first_seen": meta.get("first_seen", "legacy"),
                "last_seen": meta.get("last_seen", "unknown"),
                "speed": strip_unit(meta.get("speed", "N/A"), "MB/s"),
                "latency": strip_unit(meta.get("latency", "N/A"), "ms"),
                "code": meta.get("code", "N/A"),
                "status": meta.get("status", "old"),
            })

        i = j

    return nodes


def is_ip_like(value: str) -> bool:
    value = (value or "").strip()
    if not value:
        return False
    if re.match(r"^(\d{1,3}\.){3}\d{1,3}$", value):
        return True
    if ":" in value:
        return True
    return False


def read_new_nodes_from_csv(path: Path):
    nodes = []

    total_rows = 0
    skipped_header = 0
    skipped_empty_server = 0
    skipped_zero_speed = 0
    skipped_invalid_code = 0
    skipped_malformed = 0

    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)

        for row in reader:
            if not row:
                continue

            total_rows += 1
            server = (row[0] or "").strip()

            if not is_ip_like(server):
                skipped_header += 1
                continue

            if not server:
                skipped_empty_server += 1
                continue

            if len(row) < 6:
                skipped_malformed += 1
                continue

            try:
                speed = float((row[5] or "0").strip())
            except ValueError:
                speed = 0.0

            latency = (row[4] or "").strip() if len(row) >= 5 else ""
            code = (row[6] or "").strip().upper() if len(row) >= 7 else ""

            if speed <= 0:
                skipped_zero_speed += 1
                continue

            if code in ("", "N/A", "NA"):
                skipped_invalid_code += 1
                continue

            region = normalize_region_from_code(code)

            nodes.append({
                "region": region,
                "server": server,
                "port": vless_port,
                "source": "new",
                "speed": speed,
                "latency": latency,
                "code": code,
            })

    print("CSV 读取统计：")
    print(f"  总行数：{total_rows}")
    print(f"  跳过表头/非 IP 行：{skipped_header}")
    print(f"  跳过空 IP 行：{skipped_empty_server}")
    print(f"  跳过格式异常行：{skipped_malformed}")
    print(f"  跳过 0 速率行：{skipped_zero_speed}")
    print(f"  跳过无效地区码行：{skipped_invalid_code}")
    print(f"  有效新节点：{len(nodes)}")

    return nodes


def node_key(node: dict) -> str:
    return f"{node['server']}:{node['port']}"


def merge_nodes(old_nodes, new_nodes):
    old_by_key = {node_key(node): node for node in old_nodes}
    old_by_region = {}
    new_by_region = {}

    for node in old_nodes:
        old_by_region.setdefault(node["region"], []).append(node)

    for node in new_nodes:
        new_by_region.setdefault(node["region"], []).append(node)

    all_regions = set(old_by_region) | set(new_by_region)
    ordered_regions = [r for r in REGION_ORDER if r in all_regions]
    ordered_regions += sorted(r for r in all_regions if r not in REGION_ORDER)

    merged_by_region = {}
    stats = []
    global_seen = set()

    for region in ordered_regions:
        combined = []

        for raw_node in new_by_region.get(region, []):
            key = node_key(raw_node)
            if key in global_seen:
                continue
            global_seen.add(key)

            old_node = old_by_key.get(key)
            if old_node:
                node = dict(raw_node)
                node["status"] = "active"
                node["first_seen"] = old_node.get("first_seen") or "legacy"
                node["last_seen"] = now_time
            else:
                node = dict(raw_node)
                node["status"] = "new"
                node["first_seen"] = now_time
                node["last_seen"] = now_time

            combined.append(node)

        for old_node in old_by_region.get(region, []):
            key = node_key(old_node)
            if key in global_seen:
                continue
            global_seen.add(key)

            node = dict(old_node)
            node["status"] = "old"
            node.setdefault("first_seen", "legacy")
            node.setdefault("last_seen", "unknown")
            node.setdefault("speed", "N/A")
            node.setdefault("latency", "N/A")
            node.setdefault("code", "N/A")
            combined.append(node)

        kept = combined[:max_nodes_per_region]
        merged_by_region[region] = kept

        old_count = len(old_by_region.get(region, []))
        measured_count = len(new_by_region.get(region, []))
        unique_count = len(combined)
        final_count = len(kept)
        dropped_count = max(unique_count - final_count, 0)

        stats.append({
            "region": region,
            "old": old_count,
            "new": measured_count,
            "unique": unique_count,
            "final": final_count,
            "dropped": dropped_count,
        })

    return ordered_regions, merged_by_region, stats


def build_meta_line(node: dict) -> str:
    first_seen = node.get("first_seen") or "legacy"
    last_seen = node.get("last_seen") or "unknown"
    speed = format_speed(node.get("speed", "N/A"))
    latency = format_latency(node.get("latency", "N/A"))
    code = (node.get("code") or "N/A").strip().upper()
    status = node.get("status") or "old"

    return (
        "# CFST-META: "
        f"first_seen={first_seen}; "
        f"last_seen={last_seen}; "
        f"speed={speed}; "
        f"latency={latency}; "
        f"code={code}; "
        f"status={status}"
    )


def build_node_block(region: str, node_no: int, node: dict) -> str:
    cn, _en = REGION_INFO.get(region, REGION_INFO["OTHER"])
    server = node["server"]
    port = node["port"]
    return "\n".join([
        build_meta_line(node),
        f"- name: CF-优选-{cn} {node_no:02d}",
        "  type: vless",
        f"  server: {server}",
        f"  port: {port}",
        f"  uuid: {vless_uuid}",
        "  cipher: none",
        "  tls: true",
        "  udp: true",
        f"  servername: {vless_servername}",
        "  network: ws",
        "  ws-opts:",
        f"    path: {vless_ws_path}",
        "    headers:",
        f"      Host: {vless_host}",
        f"  client-fingerprint: {vless_fingerprint}",
        "",
    ])


def build_cf_sections(ordered_regions, merged_by_region) -> str:
    parts = []
    for region in ordered_regions:
        nodes = merged_by_region.get(region, [])
        if not nodes:
            continue
        cn, en = REGION_INFO.get(region, REGION_INFO["OTHER"])
        parts.append("################################################################")
        parts.append(f"# {cn}优选 ({en})")
        parts.append("################################################################")
        parts.append("")
        for idx, node in enumerate(nodes, start=1):
            parts.append(build_node_block(region, idx, node))
    return "\n".join(parts).rstrip() + "\n\n"


def remove_old_cf_sections(text: str) -> str:
    lines = text.splitlines(keepends=True)
    output = []
    i = 0

    while i < len(lines):
        if lines[i].lstrip().startswith("###") and i + 2 < len(lines):
            header_line = lines[i + 1].strip()
            if CF_SECTION_HEADER_RE.match(header_line):
                i += 3
                while i < len(lines):
                    if re.match(r"^proxy-groups:\s*$", lines[i]):
                        break
                    if lines[i].lstrip().startswith("###") and i + 2 < len(lines):
                        next_header_line = lines[i + 1].strip()
                        if CF_SECTION_HEADER_RE.match(next_header_line):
                            break
                    i += 1
                continue

        output.append(lines[i])
        i += 1

    return "".join(output)


def insert_cf_sections(text: str, cf_sections: str) -> str:
    marker = re.search(r"^proxy-groups:\s*$", text, flags=re.MULTILINE)
    if not marker:
        raise RuntimeError("未找到顶级 proxy-groups:，无法确定 CF 优选节点插入位置。")

    before = text[:marker.start()].rstrip() + "\n\n"
    after = text[marker.start():].lstrip("\n")
    return before + cf_sections + after


def get_top_n_cf_node_names(ordered_regions, merged_by_region, top_n: int = 10):
    candidates = []
    for region in ordered_regions:
        cn, _en = REGION_INFO.get(region, REGION_INFO["OTHER"])
        for idx, node in enumerate(merged_by_region.get(region, []), start=1):
            node_name = f"CF-优选-{cn} {idx:02d}"
            raw_speed = node.get("speed", 0)
            try:
                speed_val = float(raw_speed)
            except (TypeError, ValueError):
                speed_val = -1.0
            is_fresh = 1 if node.get("status") in ("new", "active") else 0
            candidates.append((is_fresh, speed_val, node_name))

    candidates.sort(key=lambda x: (x[0], x[1]), reverse=True)
    return [name for _fresh, _spd, name in candidates[:top_n]]


def upsert_cfst_proxy_group(text: str, top_node_names, group_name: str = "CFST", group_type: str = "url-test") -> str:
    if not top_node_names:
        return text

    marker = re.search(r"^proxy-groups:\s*$", text, flags=re.MULTILINE)
    if not marker:
        return text

    after_header = text[marker.end():]
    indent_match = re.search(r"^(?P<indent>[ \t]*)- name:", after_header, flags=re.MULTILINE)
    indent = indent_match.group("indent") if indent_match else "  "

    lines = [
        f"{indent}# CFST-GROUP-START",
        f"{indent}- name: {group_name}",
        f"{indent}  type: {group_type}",
    ]
    if group_type == "url-test":
        lines.extend([
            f"{indent}  url: https://www.gstatic.com/generate_204",
            f"{indent}  interval: 300",
            f"{indent}  tolerance: 50",
        ])
    lines.append(f"{indent}  proxies:")
    for name in top_node_names:
        lines.append(f"{indent}    - {name}")
    lines.append(f"{indent}# CFST-GROUP-END")

    block = "\n".join(lines) + "\n"

    existing_re = re.compile(
        r"^[ \t]*# CFST-GROUP-START\n.*?^[ \t]*# CFST-GROUP-END\n?",
        flags=re.MULTILINE | re.DOTALL,
    )
    if existing_re.search(text):
        return existing_re.sub(block, text, count=1)

    insert_pos = marker.end()
    return text[:insert_pos] + "\n" + block + text[insert_pos:].lstrip("\n")


def build_report(stats) -> str:
    report_lines = []
    updated_stats = [item for item in stats if item["new"] > 0]

    report_lines.append("### 📊 本次更新地区")
    report_lines.append("")

    if not updated_stats:
        report_lines.append("本次没有解析到新增有效地区节点。")
        return "\n".join(report_lines) + "\n"

    report_lines.append("| 区域 | 原有 | 新增 | 去重后 | 保留 | 淘汰 |")
    report_lines.append("|---|---:|---:|---:|---:|---:|")

    for item in updated_stats:
        region = item["region"]
        cn, _en = REGION_INFO.get(region, REGION_INFO["OTHER"])
        flag = REGION_FLAG.get(region, REGION_FLAG["OTHER"])
        region_label = f"{cn} {flag}"
        report_lines.append(
            f"| {region_label} | {item['old']} | {item['new']} | {item['unique']} | {item['final']} | {item['dropped']} |"
        )

    return "\n".join(report_lines) + "\n"


original_text = target_file.read_text(encoding="utf-8")
old_nodes = read_existing_cf_nodes(original_text)
new_nodes = read_new_nodes_from_csv(result_csv)

if not new_nodes:
    raise RuntimeError("本次 result.csv 未解析出任何有效新节点，停止更新 Personal_Use_ALL.yaml，避免无效测速结果污染配置。")

ordered_regions, merged_by_region, stats = merge_nodes(old_nodes, new_nodes)
cf_sections = build_cf_sections(ordered_regions, merged_by_region)
without_old_cf = remove_old_cf_sections(original_text)
updated_text = insert_cf_sections(without_old_cf, cf_sections)

top_cfst_names = get_top_n_cf_node_names(ordered_regions, merged_by_region, top_n=cfst_group_top_n)
updated_text = upsert_cfst_proxy_group(
    updated_text,
    top_cfst_names,
    group_name=cfst_group_name,
    group_type=cfst_group_type,
)

backup_file = target_file.with_suffix(target_file.suffix + ".bak")
backup_file.write_text(original_text, encoding="utf-8")
target_file.write_text(updated_text, encoding="utf-8")

report = build_report(stats)
report_file.write_text(report, encoding="utf-8")

updated_stats = [item for item in stats if item["new"] > 0]

print("终端摘要：")
if not updated_stats:
    print("本次没有解析到新增有效地区节点。")
else:
    for item in updated_stats:
        region = item["region"]
        cn, _en = REGION_INFO.get(region, REGION_INFO["OTHER"])
        print(
            f"{cn}："
            f"原有 {item['old']} / "
            f"新增 {item['new']} / "
            f"去重后 {item['unique']} / "
            f"保留 {item['final']} / "
            f"淘汰 {item['dropped']}"
        )

print(f"\n策略组 [{cfst_group_name}] 已更新（共 {len(top_cfst_names)} 个节点）：")
for idx, name in enumerate(top_cfst_names, start=1):
    print(f"  {idx}. {name}")

PYTHON_EOF

if [ ! -s "$REPORT_FILE" ]; then
    echo "错误：未生成更新报告：$REPORT_FILE"
    exit 1
fi

# ==============================================================================
# 7. 提交并推送 private_config 中的 Personal_Use_ALL.yaml
# ==============================================================================

print_section "提交配置变更"

cd "$PRIVATE_REPO_DIR" || exit 1

git add "$PRIVATE_TARGET_RELATIVE_PATH"

if git diff --cached --quiet; then
    echo "Personal_Use_ALL.yaml 没有有效变更，跳过 commit。"
    COMMIT_STATUS="无变更，未提交"
else
    run_quiet "提交 private_config 变更" git commit -m "Cron: update OpenClash CFST nodes [$NOW_TIME]"
    COMMIT_STATUS="已提交"
fi

print_section "推送 GitHub"
run_quiet "推送前同步私人仓库" git pull --rebase --autostash -X theirs "$PRIVATE_GIT_REMOTE" "$PRIVATE_GIT_BRANCH"
run_quiet "推送私人仓库" git push "$PRIVATE_GIT_REMOTE" "$PRIVATE_GIT_BRANCH"

# ==============================================================================
# 8. DingTalk 发送更新信息
# ==============================================================================

END_TIME="$(date '+%Y-%m-%d %H:%M')"
END_EPOCH="$(date '+%s')"
ELAPSED_SECONDS=$((END_EPOCH - START_EPOCH))
ELAPSED_TEXT="$(format_duration_seconds "$ELAPSED_SECONDS")"

DING_TITLE="CFST OpenClash 节点更新"
DING_TEXT="### 🚀 OpenClash (CFST)节点更新

- **开始时间**：$START_TIME
- **结束时间**：$END_TIME
- **总耗时**：$ELAPSED_TEXT
- **Git 状态**：$COMMIT_STATUS

$(cat "$REPORT_FILE")"

notify_dingtalk_private_markdown "$DING_TITLE" "$DING_TEXT"

# ==============================================================================
# 9. 清理本次临时结果
# ==============================================================================

rm -f "$RESULT_CSV"
rm -f "$DATA_DIR"/result_*.csv
rm -f "$DATA_DIR/result.txt"
rm -f "$DATA_DIR/data.yaml"
rm -f "$DATA_DIR/cfst-docker-last.log"

print_section "任务完成"
printf '状态：完成\n'
printf '钉钉报告：%s\n' "$REPORT_FILE"
printf '完整日志：%s\n' "$FULL_LOG_FILE"
