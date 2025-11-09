#!/bin/bash
# ==============================================================================
#  riviera_space_sweeper_rsync.sh
# ------------------------------------------------------------------------------
#  目标：在 Riviera 的 DSM 上定期检查本地卷可用空间；当“可用 < 低水位(THRESHOLD)”
#        时，按“最旧优先”把监控视频从本地（SRC_DIR）“移动”到 Beverly 的 NFS
#        共享（MOUNT_POINT / SITE_TAG 目录下），直到达到“高水位(RECOVER_TARGET)”
#        或者达到单次上限 MAX_FILES_PER_RUN 为止。
#
#  关键点：
#   - “移动”通过 rsync 实现：复制成功后删除源文件（--remove-source-files）。
#   - 断点续传/就地写入：--partial --inplace 组合。
#   - 兼容 NFS root_squash：不保留 owner/group（--no-owner --no-group / -rltD）。
#   - 传输后若仅属性失败但数据完整：仍视为成功（避免源已删重复报错）。
#   - 避免并发：flock 优先，若无 flock，用“noclobber 锁”兜底。
#   - find 支持 -printf 用它，不支持时用 stat 兜底，保证最旧优先排序。
#   - 高/低水位：THRESHOLD 触发、RECOVER_TARGET 停止，避免频繁抖动。
#   - 可选：DEST_MIN_FREE（目标端保底可用空间）不足则跳过本次。
#   - 可选：CLEAN_EMPTY_DIRS=1，移动后清理源中的空目录。
#
#  作者：你现在这位小助手 🐧
# ==============================================================================

set -euo pipefail  # -e: 任一命令非0退出; -u: 未定义变量报错; -o pipefail: 管道失败连坐

# ==========【可配置项】可用环境变量/命令行参数覆盖（见下方“解析参数”） ==========
THRESHOLD="${THRESHOLD:-100G}"       # 低水位：本地可用 < THRESHOLD 时触发搬运（如 800G）
RECOVER_TARGET="${RECOVER_TARGET:-}" # 高水位：达到即停止；留空=等于 THRESHOLD（无滞后）

VOLUME_PATH="${VOLUME_PATH:-/volume1}"           # 本地卷根（用于 df 读取可用空间）
SRC_DIR="${SRC_DIR:-/volume1/Storage_Riviera}"   # 源目录（本地录像目录，含子目录）
SITE_TAG="${SITE_TAG:-Riviera}"                  # 站点标签（目标下加一层区分目录）

# NFS 目标（Beverly）
NFS_SERVER="${NFS_SERVER:-192.168.12.200}"       # NFS 服务器地址（Beverly DSM）
NFS_EXPORT="${NFS_EXPORT:-/volume1/Camera_Archive}" # NFS 导出路径（Beverly 共享目录）
MOUNT_POINT="${MOUNT_POINT:-/mnt/beverly_archive}"  # 本机挂载点（Riviera 上）
NFS_OPTS="${NFS_OPTS:-rw,vers=3,nolock}"         # 首选 v3，失败再自动尝试 v4

MIN_AGE_MIN="${MIN_AGE_MIN:-30}"                 # 跳过最近 N 分钟内修改的文件（避免搬正在写的录像）
EXTS="${EXTS:-mp4,mkv,avi,ts,flv,mov}"           # 扩展名过滤（不区分大小写，逗号分隔）
MAX_FILES_PER_RUN="${MAX_FILES_PER_RUN:-0}"      # 单次最多移动文件数（0=不限制）
BWLIMIT="${BWLIMIT:-0}"                          # rsync 限速（如 80M；0=不限）
CLEAN_EMPTY_DIRS="${CLEAN_EMPTY_DIRS:-1}"        # 是否清理空目录（1=是，0=否）

DEST_MIN_FREE="${DEST_MIN_FREE:-0}"              # 目标端保底可用（如 200G）；0/空=不启用

LOG_FILE="${LOG_FILE:-/var/log/riviera_space_sweeper_rsync.log}" # 日志文件
LOCK_FILE="/var/run/riviera_space_sweeper_rsync.lock"            # 并发锁文件
DRY_RUN="${DRY_RUN:-0}"                           # 1=演练只打印不执行，0=真实执行

# ==========【优先级降低】尽量让出系统资源 ==========
command -v ionice >/dev/null 2>&1 && ionice -c2 -n7 -p $$ >/dev/null 2>&1 || true
renice +15 -p $$ >/dev/null 2>&1 || true

# ==========【通用函数】==========
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
fail(){ log "ERROR: $*"; exit 1; }
need_cmd(){ command -v "$1" >/dev/null 2>&1 || fail "缺少必需命令：$1"; }

# 将 200G/500M/1T 等容量转为 KB（整数）；纯数字视为 KB
to_kb(){
  local s="${1^^}" num unit
  if [[ "$s" =~ ^([0-9]+)([KMGTP])B?$ ]]; then
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in
      K) echo $(( num ));;
      M) echo $(( num * 1024 ));;
      G) echo $(( num * 1024 * 1024 ));;
      T) echo $(( num * 1024 * 1024 * 1024 ));;
      P) echo $(( num * 1024 * 1024 * 1024 * 1024 ));;
    esac
  elif [[ "$s" =~ ^[0-9]+$ ]]; then
    echo "$s"
  else
    fail "无法解析容量：$1（示例：200G、500M、1T）"
  fi
}

free_kb(){ df -Pk "$VOLUME_PATH" 2>/dev/null | awk 'NR==2{print $4}'; }       # 本地可用 KB
dest_free_kb(){ df -Pk "$MOUNT_POINT" 2>/dev/null | awk 'NR==2{print $4}'; } # 目标可用 KB

# 用“数组”构造扩展名表达式，避免字符串转义/顺序问题
declare -a EXT_ARGS=()
build_ext_args(){
  EXT_ARGS=()
  local IFS=',' e
  for e in $1; do
    e="${e//[[:space:]]/}"          # 去空白
    [[ -z "$e" ]] && continue
    EXT_ARGS+=(-iname "*.${e}")     # 形如：-iname '*.mp4'
    EXT_ARGS+=(-o)                  # 多个扩展名之间用 -o
  done
  (( ${#EXT_ARGS[@]} > 0 )) && unset 'EXT_ARGS[${#EXT_ARGS[@]}-1]'  # 去掉末尾多余 -o
}

# 使用说明
usage(){
cat <<'EOF'
用法: riviera_space_sweeper_rsync.sh [选项]
  -t, --threshold SIZE   启动阈值（低水位），可用 < SIZE 时触发（默认: 100G）
  -R, --recover  SIZE    恢复目标（高水位），达到即停止（默认: 等于启动阈值）
  -v, --volume   PATH    本地卷根（默认: /volume1）
  -s, --src      DIR     源目录（默认: /volume1/Storage_Riviera）
      --site     NAME    站点标签（默认: Riviera）
  -S, --server   IP      NFS 服务器（默认: 192.168.12.200）
  -E, --export   PATH    NFS 导出路径（默认: /volume1/Camera_Archive）
  -M, --mount    DIR     本机挂载点（默认: /mnt/beverly_archive）
  -y, --min-age  MIN     跳过最近 N 分钟内修改的文件（默认: 30）
  -e, --exts     LIST    扩展名列表（默认: mp4,mkv,avi,ts,flv,mov）
  -m, --max      N       单次最多移动数（默认: 0=不限）
      --bwlimit  VAL     rsync 限速（如 80M；默认: 0=不限）
  -n, --dry-run          演练模式（只打印不执行）
  -l, --log      FILE    日志路径（默认: /var/log/riviera_space_sweeper_rsync.log）
  -h, --help             显示帮助
环境变量（与参数等效）：
  THRESHOLD, RECOVER_TARGET, VOLUME_PATH, SRC_DIR, SITE_TAG, NFS_SERVER,
  NFS_EXPORT, MOUNT_POINT, NFS_OPTS, MIN_AGE_MIN, EXTS, MAX_FILES_PER_RUN,
  BWLIMIT, CLEAN_EMPTY_DIRS, DEST_MIN_FREE, LOG_FILE, DRY_RUN
EOF
}

# ==========【解析参数】支持长短参数 ==========
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--threshold) THRESHOLD="$2"; shift 2;;
    -R|--recover)   RECOVER_TARGET="$2"; shift 2;;
    -v|--volume)    VOLUME_PATH="$2"; shift 2;;
    -s|--src)       SRC_DIR="$2"; shift 2;;
    --site)         SITE_TAG="$2"; shift 2;;
    -S|--server)    NFS_SERVER="$2"; shift 2;;
    -E|--export)    NFS_EXPORT="$2"; shift 2;;
    -M|--mount)     MOUNT_POINT="$2"; shift 2;;
    -y|--min-age)   MIN_AGE_MIN="$2"; shift 2;;
    -e|--exts)      EXTS="$2"; shift 2;;
    -m|--max)       MAX_FILES_PER_RUN="$2"; shift 2;;
    --bwlimit)      BWLIMIT="$2"; shift 2;;
    -n|--dry-run)   DRY_RUN=1; shift;;
    -l|--log)       LOG_FILE="$2"; shift 2;;
    -h|--help)      usage; exit 0;;
    *) log "忽略未知参数：$1"; shift;;
  esac
done

# ==========【前置检查】必要命令与目录 ==========
need_cmd df; need_cmd find; need_cmd rsync; need_cmd mount; need_cmd awk; need_cmd sort; need_cmd wc; need_cmd stat
[ -d "$VOLUME_PATH" ] || fail "卷不存在：$VOLUME_PATH"
[ -d "$SRC_DIR" ]     || fail "源目录不存在：$SRC_DIR"
mkdir -p "$MOUNT_POINT" "$(dirname "$LOG_FILE")" || true

# ==========【并发锁】flock 优先；无 flock 用 noclobber 文件锁 ==========
cleanup_lock(){ [ -n "${_LOCK_MODE:-}" ] && [ "$_LOCK_MODE" = "noclobber" ] && rm -f "$LOCK_FILE" || true; }
trap 'cleanup_lock' EXIT INT TERM

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE" || fail "无法创建锁文件：$LOCK_FILE"
  flock -n 9 || { log "已有实例在运行，退出。"; exit 0; }   # 非阻塞获取锁；失败则退出
  _LOCK_MODE="flock"
else
  ( set -o noclobber; : > "$LOCK_FILE" ) 2>/dev/null || { log "已有实例在运行，退出。"; exit 0; }
  _LOCK_MODE="noclobber"
fi

# ==========【确保 NFS 已挂载】优先 v3，失败再试 v4 ==========
ensure_mount(){
  grep -qs " $MOUNT_POINT " /proc/mounts && return 0
  log "NFS 未挂载，尝试 v3：$NFS_SERVER:$NFS_EXPORT -> $MOUNT_POINT"
  mount -t nfs -o "$NFS_OPTS" "$NFS_SERVER:$NFS_EXPORT" "$MOUNT_POINT" && { log "挂载成功（v3）"; return 0; }
  log "v3 失败，尝试 v4…"
  mount -t nfs -o rw,vers=4 "$NFS_SERVER:$NFS_EXPORT" "$MOUNT_POINT" && { log "挂载成功（v4）"; return 0; }
  fail "NFS 挂载失败，请检查 exportfs/权限/路径/防火墙"
}
ensure_mount

# 目标站点目录（含站点标签层）
DST_DIR="$MOUNT_POINT/$SITE_TAG"
mkdir -p "$DST_DIR" || fail "无法创建目录：$DST_DIR"

# ==========【阈值/高水位计算】及当前空间状态 ==========
THRESHOLD_KB="$(to_kb "$THRESHOLD")"
if [ -z "${RECOVER_TARGET:-}" ] || [ "$RECOVER_TARGET" = "0" ]; then
  RECOVER_TARGET_KB="$THRESHOLD_KB"   # 不设置则与低水位相同（无滞后）
else
  RECOVER_TARGET_KB="$(to_kb "$RECOVER_TARGET")"
  if [ "$RECOVER_TARGET_KB" -lt "$THRESHOLD_KB" ]; then
    log "注意：恢复目标($RECOVER_TARGET) < 启动阈值($THRESHOLD)，自动对齐为启动阈值。"
    RECOVER_TARGET_KB="$THRESHOLD_KB"
  fi
fi

CUR_FREE_KB="$(free_kb)"; [ -n "$CUR_FREE_KB" ] || fail "df 读取失败"
log "卷=$VOLUME_PATH；当前可用=$(awk -v k="$CUR_FREE_KB" 'BEGIN{printf "%.2fGB",k/1024/1024}')；启动阈值=$THRESHOLD；恢复目标=$([ "$RECOVER_TARGET_KB" -eq "$THRESHOLD_KB" ] && echo 同阈值 || echo "$RECOVER_TARGET")；源=$SRC_DIR；目标=$DST_DIR"

# 若未低于启动阈值，不搬运（避免无谓扫描）
if [ "$CUR_FREE_KB" -ge "$THRESHOLD_KB" ]; then
  log "可用空间未低于启动阈值，无需搬运。"; exit 0
fi

# ==========【目标端保底可用】不足则暂停（可选） ==========
if [ -n "${DEST_MIN_FREE:-}" ] && [ "$DEST_MIN_FREE" != "0" ]; then
  DEST_MIN_FREE_KB="$(to_kb "$DEST_MIN_FREE")"
  CUR_DEST_FREE_KB="$(dest_free_kb || true)"
  [ -z "$CUR_DEST_FREE_KB" ] && fail "无法读取目标挂载点可用空间"
  log "目标挂载点=$MOUNT_POINT；可用=$(awk -v k="$CUR_DEST_FREE_KB" 'BEGIN{printf "%.2fGB",k/1024/1024}')；目标保底=$DEST_MIN_FREE"
  if [ "$CUR_DEST_FREE_KB" -lt "$DEST_MIN_FREE_KB" ]; then
    log "目标端可用空间低于保底，暂停本次搬运。"; exit 0
  fi
fi

# ==========【生成候选清单】最旧优先 ==========
TMP_LIST="$(mktemp -t rsync_sweep.XXXXXX)" || fail "mktemp 失败"
trap 'rm -f "$TMP_LIST"; cleanup_lock' EXIT INT TERM
build_ext_args "$EXTS"

# 优先使用 GNU find 的 -printf（快且无需调用 stat）；无则走 stat 兜底
if find / -maxdepth 0 -printf '' >/dev/null 2>&1; then
  if (( ${#EXT_ARGS[@]} > 0 )); then
    find "$SRC_DIR" -type f -mmin +"$MIN_AGE_MIN" \( "${EXT_ARGS[@]}" \) -printf '%T@\t%p\n' \
      | sort -n -k1,1 > "$TMP_LIST"
  else
    find "$SRC_DIR" -type f -mmin +"$MIN_AGE_MIN" -printf '%T@\t%p\n' \
      | sort -n -k1,1 > "$TMP_LIST"
  fi
else
  # 兜底：用 stat 取 mtime(epoch)。注意：xargs -0 能处理包含空格/中文的路径。
  if (( ${#EXT_ARGS[@]} > 0 )); then
    find "$SRC_DIR" -type f -mmin +"$MIN_AGE_MIN" \( "${EXT_ARGS[@]}" \) -print0 \
      | xargs -0 -I{} sh -c 'printf "%s\t%s\n" "$(stat -c %Y "{}")" "{}"' \
      | sort -n -k1,1 > "$TMP_LIST"
  else
    find "$SRC_DIR" -type f -mmin +"$MIN_AGE_MIN" -print0 \
      | xargs -0 -I{} sh -c 'printf "%s\t%s\n" "$(stat -c %Y "{}")" "{}"' \
      | sort -n -k1,1 > "$TMP_LIST"
  fi
fi

CNT="$(wc -l < "$TMP_LIST" | awk '{print $1}')"
[ "$CNT" -eq 0 ] && { log "无可移动文件（可能都 < ${MIN_AGE_MIN} 分钟或扩展名未匹配）。"; exit 0; }
log "候选文件数：$CNT（最旧优先）"

# ==========【rsync 参数】root_squash 友好 + 可选限速/演练 ==========
# 说明：
#  -rltD      : 近似 -a 但不保留 owner/group（避免 NFS chown 失败）
# --no-owner  : 再强调不保留 owner
# --no-group  : 再强调不保留 group
# --partial   : 断点续传保留未完成文件
# --inplace   : 原地写入，减少额外占用；NFS 上更友好
# --remove-source-files : 复制成功后删除源文件 => 实现“移动”
# --chmod     : 统一目标权限，避免奇怪 umask
RSYNC_ARGS=(
  -rltD
  --no-owner --no-group
  --partial --inplace
  --remove-source-files
  --info=stats2,progress2
  --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r
)
[ "$BWLIMIT" != "0" ] && RSYNC_ARGS+=(--bwlimit="$BWLIMIT")
[ "$DRY_RUN" -eq 1 ] && RSYNC_ARGS+=(--dry-run)

# ==========【逐个搬运】达到高水位/单次上限即停止 ==========
moved=0
while IFS=$'\t' read -r _ts path; do
  # 达到“恢复目标”（高水位）则停止（形成滞后，避免抖动）
  CUR_FREE_KB="$(free_kb)"
  [ "$CUR_FREE_KB" -ge "$RECOVER_TARGET_KB" ] && { log "已达恢复目标，停止搬运。"; break; }

  # 记录源文件大小，用于判断“属性失败但数据己完整”的场景
  SRC_SIZE="$(stat -c %s -- "$path" 2>/dev/null || echo 0)"

  # 生成目标路径（保持源目录层级结构）
  rel="${path#$SRC_DIR/}"
  target_dir="$DST_DIR/$(dirname "$rel")"
  target_path="$DST_DIR/$rel"
  mkdir -p "$target_dir" || { log "创建目录失败：$target_dir"; continue; }

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN 将移动：$path  ->  $target_path"
  else
    try=1 ok=0
    while [ $try -le 3 ]; do
      log "rsync 第 ${try}/3 次：$path"
      set +e
      rsync "${RSYNC_ARGS[@]}" -- "$path" "$target_path"
      rc=$?
      set -e

      if [ $rc -eq 0 ]; then
        ok=1
      else
        # 仅属性失败（如 chown），但数据已完整：视为成功，避免重复重试/误删
        if [ -f "$target_path" ] && [ "$SRC_SIZE" -gt 0 ]; then
          DST_SIZE="$(stat -c %s -- "$target_path" 2>/dev/null || echo 0)"
          if [ "$DST_SIZE" -eq "$SRC_SIZE" ]; then
            log "rsync 返回 rc=$rc，但目标文件大小匹配（多为属性/权限问题），视为成功。"
            ok=1
          fi
        fi
      fi

      [ $ok -eq 1 ] && break
      log "rsync 失败（rc=$rc），10s 后重试…"; sleep 10
      try=$((try+1))
    done

    if [ $ok -ne 1 ]; then
      log "放弃：$path"; continue
    fi
  fi

  moved=$((moved+1))
  if [ "$MAX_FILES_PER_RUN" -gt 0 ] && [ "$moved" -ge "$MAX_FILES_PER_RUN" ]; then
    log "达到单次上限 MAX_FILES_PER_RUN=$MAX_FILES_PER_RUN，提前结束。"; break
  fi
done < "$TMP_LIST"

# ==========【清理空目录】保持源目录整洁（可关） ==========
if [ "$CLEAN_EMPTY_DIRS" -eq 1 ]; then
  # -empty 仅删除“完全空”的目录；2>/dev/null 防止无权限警告中断
  find "$SRC_DIR" -type d -empty -delete 2>/dev/null || true
fi

# ==========【收尾日志】汇总与提醒 ==========
CUR_FREE_KB="$(free_kb)"
log "本次移动：$moved；当前可用：$(awk -v k="$CUR_FREE_KB" 'BEGIN{printf "%.2fGB",k/1024/1024}')；启动阈值：$THRESHOLD；恢复目标：$([ "$RECOVER_TARGET_KB" -eq "$THRESHOLD_KB" ] && echo 同阈值 || echo "$RECOVER_TARGET")"
[ "$CUR_FREE_KB" -lt "$RECOVER_TARGET_KB" ] && log "注意：仍未达到恢复目标，可能无更多可移或受上限限制。"

exit 0

# ==============================================================================
# 使用示例：
# 1) 演练模式（不执行）：强触发（阈值>当前可用），最多列 10 个候选，限速 80M
#    DRY_RUN=1 THRESHOLD=950G MAX_FILES_PER_RUN=10 MIN_AGE_MIN=30 BWLIMIT=80M \
#      bash /root/riviera_space_sweeper_rsync.sh
#
# 2) 生产运行：低水位 800G，高水位 900G，限速 80M，每次最多 200 个
#    THRESHOLD=800G RECOVER_TARGET=900G MAX_FILES_PER_RUN=200 MIN_AGE_MIN=60 BWLIMIT=80M \
#      bash /root/riviera_space_sweeper_rsync.sh
#
# 3) 启用目标端保底空间（例如 200G），不足则跳过
#    DEST_MIN_FREE=200G THRESHOLD=800G RECOVER_TARGET=900G \
#      bash /root/riviera_space_sweeper_rsync.sh
#
# 4) DSM 计划任务（每 15~30 分钟一次，建议）：
#    /bin/bash /root/riviera_space_sweeper_rsync.sh -t 800G --bwlimit 80M -m 200 -y 60
# ==============================================================================
