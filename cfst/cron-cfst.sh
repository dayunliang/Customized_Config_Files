#!/bin/sh

# ==============================================================================
# CFST Cron 自动执行脚本【每日一次 + OpenClash Personal_Use_ALL.yaml 合并版】
# 修改时间：2026-06-11  Asia/Shanghai / UTC+8
# ==============================================================================
#
# 本脚本职责：
#   1. 每次 cron 执行时，先拉取公开仓库 cfst 最新配置；
#   2. 运行 CloudflareSpeedTest / docker compose，生成 data/result.csv；
#   3. 将 result.csv 转换为 OpenClash proxies 节点；
#   4. 拉取私人仓库 dayunliang/private_config；
#   5. 修改私人仓库中的：
#        Lean/files/etc/openclash/config/Personal_Use_ALL.yaml
#   6. 按区域类别合并已有 CF 优选节点与本次新节点；
#   7. 按“新节点优先、旧节点靠后”的顺序去重；
#   8. 每个区域最多保留 10 个节点；
#   9. 提交并 push 修改后的 Personal_Use_ALL.yaml；
#  10. 通过 DingTalk 发送更新统计信息。
#
# 重要说明：
#   - 本版已经取消“每日两次 / 第一轮第二轮合并”的旧逻辑；
#   - 现在每次 cron 都是独立完整更新；
#   - 本脚本不会再提交 cfst/data/result.csv 到公开仓库；
#   - 只会提交 private_config 中的 Personal_Use_ALL.yaml。
#
# 本次修复重点：
#   - docker compose 不再前台无限等待；
#   - 使用宿主机侧超时控制，最多等待 CFST 容器运行 20 分钟；
#   - 不依赖容器内部是否存在 timeout 命令；
#   - 不再把 timeout 写进 docker-compose command，避免被解释成：
#         ./cfst timeout 20m -n ...
#   - Python 合并 result.csv 时过滤下载速度为 0 的结果；
#   - Python 合并 result.csv 时过滤地区码为空 / N/A / NA 的结果；
#   - 避免测速 URL 异常时将大量 0.00 MB/s 节点写入 OpenClash。
#   - 为 CF 优选节点写入 CFST-META 注释，记录 first_seen / last_seen / speed / latency / code / status。
#
# 安全建议：
#   - 不建议把 DingTalk AppKey / AppSecret / UserID 明文写死在脚本中；
#   - 推荐在 /root/cfst/.dingtalk.env 中保存：
#
#       DING_APP_KEY='你的 AppKey'
#       DING_APP_SECRET='你的 AppSecret'
#       DING_USER_ID='你的 UserID'
#
# ============================================================================== 

set -eu

# ==============================================================================
# 1. 基础变量
# ============================================================================== 

WORK_DIR="/root/cfst"
DATA_DIR="$WORK_DIR/data"
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"

PUBLIC_GIT_REMOTE="origin"
PUBLIC_GIT_BRANCH="main"

PRIVATE_REPO_DIR="/root/private_config"
PRIVATE_REPO_SSH="git@github.com:dayunliang/private_config.git"
PRIVATE_GIT_REMOTE="origin"
PRIVATE_GIT_BRANCH="main"
PRIVATE_TARGET_RELATIVE_PATH="Lean/files/etc/openclash/config/Personal_Use_ALL.yaml"
PRIVATE_TARGET_FILE="$PRIVATE_REPO_DIR/$PRIVATE_TARGET_RELATIVE_PATH"

GIT_USER_NAME="alpine-cron"
GIT_USER_EMAIL="cron@homelab.local"

TODAY="$(date '+%Y-%m-%d')"
START_TIME="$(date '+%Y-%m-%d %H:%M')"
START_EPOCH="$(date '+%s')"

# 兼容原有变量名：后续 Git commit 仍使用任务开始时间。
NOW_TIME="$START_TIME"

RESULT_CSV="$DATA_DIR/result.csv"
REPORT_FILE="$DATA_DIR/openclash_update_report.md"
FULL_LOG_FILE="$DATA_DIR/cron-cfst-full.log"

# ==============================================================================
# 1.1 CFST 容器运行保护变量
# ==============================================================================
#
# 说明：
#   - 当前 cfst 是通过实时拉取 docker-compose.yml 后启动；
#   - compose 文件中的 command 会被追加到镜像 ENTRYPOINT 后面；
#   - 如果在 command 中写 timeout 20m，实际可能变成：
#         ./cfst timeout 20m -n 200 ...
#   - 因此这里统一由宿主机脚本监控容器运行时长。
#
# ==============================================================================

CFST_CONTAINER_NAME="cfst"

# 最大等待时间，单位：秒。
# 1200 秒 = 20 分钟。
CFST_MAX_WAIT_SECONDS=43200

# 每次检查间隔，单位：秒。
CFST_WAIT_STEP_SECONDS=10

# ==============================================================================

# 1.1 OpenClash / VLESS 节点模板变量
# ============================================================================== 

VLESS_PORT="443"
VLESS_UUID="bc398b21-15f3-484e-83c1-d99f16dc6c4a"
VLESS_SERVERNAME="b-gfw.cf-ip.cfd"
VLESS_HOST="b-gfw.cf-ip.cfd"
VLESS_WS_PATH="/?ed=2560"
VLESS_CLIENT_FINGERPRINT="chrome"

# ==============================================================================
# 1.2 DingTalk 配置
# ============================================================================== 
#
# 示例：
#
#   DING_APP_KEY='dingxxxxxxxxxxxxxxxx'
#   DING_APP_SECRET='xxxxxxxxxxxxxxxx'
#   DING_USER_ID='managerxxxx'
#
# 如果变量为空，则跳过 DingTalk，不影响主流程。
#
# ============================================================================== 

DING_APP_KEY="dingecswocgwfsntk2v2"
DING_APP_SECRET="pMiPruv-gJw6un6138ELUzGEBCyhPGk4pe3WZiEdJPPcJQlmi8JkK5Zh_uyvdHM_"
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

    TOKEN_RES="$(curl -sS -X POST "https://api.dingtalk.com/v1.0/oauth2/accessToken" \
        -H "Content-Type: application/json" \
        -d "$TOKEN_PAYLOAD" || true)"

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

    SEND_RES="$(curl -sS -X POST "https://api.dingtalk.com/v1.0/robot/oToMessages/batchSend" \
        -H "x-acs-dingtalk-access-token: $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$SEND_PAYLOAD" || true)"

    echo "DingTalk 返回：$SEND_RES"
    return 0
}


# ==============================================================================
# 2.1 终端输出格式函数
# ==============================================================================
#
# 设计目标：
#   - cron / 手动执行时只显示关键摘要；
#   - Docker / Git 的完整输出保存在日志文件中；
#   - 失败时仍然把完整日志路径打印出来，方便排查；
#   - DingTalk 继续发送 Markdown 汇总，不发送大段原始日志。
#
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
print('测速结果 Top 10：')

if not rows:
    print('未解析到有效测速节点。')
else:
    for idx, (ip, latency, speed, code) in enumerate(rows[:10], start=1):
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
# 5. 运行 CFST 测速，生成 result.csv
# ==============================================================================
#
# 这里不再直接执行：
#   docker compose up
#
# 原因：
#   - docker compose up 是前台执行；
#   - 如果 cfst 下载测速阶段卡住，cron 任务会一直挂住；
#   - 如果 compose 文件中 command 写 timeout，又可能被镜像 ENTRYPOINT 追加成：
#       ./cfst timeout 20m ...
#   - 因此这里使用宿主机侧监控方式。
#
# 工作流：
#   1. 清理旧容器；
#   2. docker compose up -d 后台启动；
#   3. 循环检查 cfst 容器是否还在运行；
#   4. 超过 CFST_MAX_WAIT_SECONDS 后强制停止；
#   5. 打印最后 100 行日志；
#   6. docker compose down 清理容器和临时网络资源；
#   7. 检查 result.csv 是否有效。
#
# ==============================================================================

rm -f "$RESULT_CSV"
rm -f "$REPORT_FILE"

print_section "运行 CFST 测速"

run_quiet "清理旧 CFST 容器" docker compose down --remove-orphans
run_quiet "后台启动 CFST 容器" docker compose up -d

CFST_WAITED_SECONDS=0
CFST_TIMEOUT_HIT=0
CFST_EXIT_CODE="unknown"

while docker ps --format '{{.Names}}' | grep -qx "$CFST_CONTAINER_NAME"; do
    if [ "$CFST_WAITED_SECONDS" -ge "$CFST_MAX_WAIT_SECONDS" ]; then
        print_warn "CFST 容器运行超过 $CFST_MAX_WAIT_SECONDS 秒，开始强制停止。"
        CFST_TIMEOUT_HIT=1
        {
            echo
            echo "==================== CFST Docker Log ===================="
            docker logs --tail=300 "$CFST_CONTAINER_NAME" 2>&1 || true
            echo "================== End CFST Docker Log =================="
            echo
        } >> "$FULL_LOG_FILE"
        docker stop "$CFST_CONTAINER_NAME" >> "$FULL_LOG_FILE" 2>&1 || true
        docker rm "$CFST_CONTAINER_NAME" >> "$FULL_LOG_FILE" 2>&1 || true
        break
    fi

    sleep "$CFST_WAIT_STEP_SECONDS"
    CFST_WAITED_SECONDS=$((CFST_WAITED_SECONDS + CFST_WAIT_STEP_SECONDS))
done

if docker ps -a --format '{{.Names}}' | grep -qx "$CFST_CONTAINER_NAME"; then
    CFST_EXIT_CODE="$(docker inspect -f '{{.State.ExitCode}}' "$CFST_CONTAINER_NAME" 2>/dev/null || printf 'unknown')"
    {
        echo
        echo "==================== CFST Docker Log ===================="
        docker logs --tail=300 "$CFST_CONTAINER_NAME" 2>&1 || true
        echo "================== End CFST Docker Log =================="
        echo
    } >> "$FULL_LOG_FILE"
fi

run_quiet "清理本次 CFST 容器" docker compose down --remove-orphans

printf '容器等待秒数：%s\n' "$CFST_WAITED_SECONDS"
printf '容器退出码：%s\n' "$CFST_EXIT_CODE"
printf '是否触发超时：%s\n' "$CFST_TIMEOUT_HIT"
printf '完整日志：%s\n' "$FULL_LOG_FILE"

if [ "$CFST_TIMEOUT_HIT" -eq 1 ]; then
    print_warn "本次 CFST 触发超时保护；如果 result.csv 有效，仍会继续后续校验。"
fi

if [ ! -s "$RESULT_CSV" ]; then
    print_error "CFST 执行完成后未生成有效 result.csv：$RESULT_CSV"
    exit 1
fi

print_cfst_csv_summary

# ==============================================================================
# 6. 合并 result.csv 到 OpenClash Personal_Use_ALL.yaml
# ============================================================================== 
#
# 这里使用内嵌 Python 做文本级合并：
#   - 读取现有 Personal_Use_ALL.yaml；
#   - 提取已有 CF-优选-* 节点；
#   - 读取本次 result.csv；
#   - 新节点优先，旧节点靠后；
#   - 按 server:port 去重；
#   - 每个区域最多保留 10 个；
#   - 删除旧 CF 优选区块；
#   - 在 proxy-groups: 之前重建新的 CF 优选区块；
#   - 非 CF 节点、proxy-groups、rule-providers、rules 原样保留。
#
# ============================================================================== 

print_section "合并 OpenClash 节点"

python3 - "$RESULT_CSV" "$PRIVATE_TARGET_FILE" "$REPORT_FILE" "$NOW_TIME" \
    "$VLESS_PORT" "$VLESS_UUID" "$VLESS_SERVERNAME" "$VLESS_HOST" "$VLESS_WS_PATH" "$VLESS_CLIENT_FINGERPRINT" <<'PYTHON_EOF'
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
    """解析单行 CFST-META 注释。

    支持格式：
      # CFST-META: first_seen=2026-06-11 09:00; last_seen=...; speed=...; latency=...; code=...; status=...
    """
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

        # 如果节点上方紧贴 CFST-META 注释，则读取旧元数据。
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

            speed = 0.0

            try:
                speed = float((row[5] or "0").strip())
            except ValueError:
                speed = 0.0

            latency = ""
            if len(row) >= 5:
                latency = (row[4] or "").strip()

            code = ""
            if len(row) >= 7:
                code = (row[6] or "").strip().upper()

            # ------------------------------------------------------------
            # 关键过滤 1：
            #   下载速度必须大于 0。
            # ------------------------------------------------------------
            if speed <= 0:
                skipped_zero_speed += 1
                continue

            # ------------------------------------------------------------
            # 关键过滤 2：
            #   地区码不能是空、N/A、NA。
            # ------------------------------------------------------------
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
    new_keys = {node_key(node) for node in new_nodes}

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

        # 1. 本次 CSV 结果优先。
        #    - 旧 YAML 没有：status=new
        #    - 旧 YAML 已有：status=active
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
                # speed / latency / code 使用本次最新测速结果。
            else:
                node = dict(raw_node)
                node["status"] = "new"
                node["first_seen"] = now_time
                node["last_seen"] = now_time

            combined.append(node)

        # 2. 本次没测到的旧节点靠后保留。
        #    - status=old
        #    - first_seen / last_seen / speed / latency / code 保留旧元数据。
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

        kept = combined[:10]
        merged_by_region[region] = kept

        old_count = len(old_by_region.get(region, []))
        measured_count = len(new_by_region.get(region, []))
        unique_count = len(combined)
        final_count = len(kept)
        dropped_count = max(unique_count - final_count, 0)
        real_new_count = sum(1 for node in combined if node.get("status") == "new")
        active_count = sum(1 for node in combined if node.get("status") == "active")
        old_kept_count = sum(1 for node in kept if node.get("status") == "old")

        stats.append({
            "region": region,
            "old": old_count,
            # 保持原有钉钉字段语义：这里的“新增”继续代表本次 CSV 有效节点数量。
            "new": measured_count,
            "unique": unique_count,
            "final": final_count,
            "dropped": dropped_count,
            # 下面三个字段用于后续排查；当前钉钉报告暂不展示，避免改变你已确认的格式。
            "real_new": real_new_count,
            "active": active_count,
            "old_kept": old_kept_count,
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
        # 识别旧 CF 区块：
        #   ################################################################
        #   # 香港优选 (Hong Kong)
        #   ################################################################
        if lines[i].lstrip().startswith("###") and i + 2 < len(lines):
            header_line = lines[i + 1].strip()
            if CF_SECTION_HEADER_RE.match(header_line):
                # 跳过当前 CF 区块，直到下一个 CF 区块头或 proxy-groups。
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


def build_report(stats) -> str:
    report_lines = []

    # 钉钉继续使用 Markdown 表格格式；
    # 终端摘要在 report_file 写入后单独输出普通文本，不受这里影响。
    # 只展示“本次有新增有效节点”的地区；本次更新为 0 的地区不展示。
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

backup_file = target_file.with_suffix(target_file.suffix + ".bak")
backup_file.write_text(original_text, encoding="utf-8")
target_file.write_text(updated_text, encoding="utf-8")

report = build_report(stats)
report_file.write_text(report, encoding="utf-8")

# 终端只输出普通文本摘要，避免 Linux 终端直接显示 Markdown 表格时出现“不对齐”。
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
rm -f "$DATA_DIR/result.txt"
rm -f "$DATA_DIR/data.yaml"
rm -f "$DATA_DIR/cfst-docker-last.log"

# 保留 REPORT_FILE，方便在 /root/cfst/data/openclash_update_report.md 查看最近一次统计。

print_section "任务完成"
printf '状态：完成\n'
printf '钉钉报告：%s\n' "$REPORT_FILE"
printf '完整日志：%s\n' "$FULL_LOG_FILE"
