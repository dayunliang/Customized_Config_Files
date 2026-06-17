#!/bin/bash
# ==============================================================================
#  riviera_space_sweeper_rsync.sh (集成钉钉告警 + 每日巡检心跳通知)
# ------------------------------------------------------------------------------
#  目标：在 Riviera 的 DSM 上定期检查本地卷可用空间；当“可用 < 低水位(THRESHOLD)”
#        时，按“最旧优先”把监控视频从本地（SRC_DIR）“移动”到 Beverly 的 NFS
#        共享，直到达到“高水位”或单次上限。
# ==============================================================================

set -euo pipefail

# ==========【钉钉告警配置】==========
ENABLE_DINGTALK="${ENABLE_DINGTALK:-1}"          # 1=开启通知，0=关闭通知
DING_APP_KEY="dingecswocgwfsntk2v2"              # 你的AppKey (RobotCode)
DING_APP_SECRET="pMiPruv-gJw6un6138ELUzGEBCyhPGk4pe3WZiEdJPPcJQlmi8JkK5Zh_uyvdHM_" # AppSecret
DING_USER_ID="manager3729"                       # 接收通知的 UserID

# ==========【可配置项】==========
THRESHOLD="${THRESHOLD:-100G}"       
RECOVER_TARGET="${RECOVER_TARGET:-}" 

VOLUME_PATH="${VOLUME_PATH:-/volume1}"           
SRC_DIR="${SRC_DIR:-/volume1/Storage_Riviera}"   
SITE_TAG="${SITE_TAG:-Riviera}"                  

NFS_SERVER="${NFS_SERVER:-192.168.12.200}"       
NFS_EXPORT="${NFS_EXPORT:-/volume1/Camera_Archive}" 
MOUNT_POINT="${MOUNT_POINT:-/mnt/beverly_archive}"  
NFS_OPTS="${NFS_OPTS:-rw,vers=3,nolock}"         

MIN_AGE_MIN="${MIN_AGE_MIN:-30}"                 
EXTS="${EXTS:-mp4,mkv,avi,ts,flv,mov}"           
MAX_FILES_PER_RUN="${MAX_FILES_PER_RUN:-0}"      
BWLIMIT="${BWLIMIT:-0}"                          
CLEAN_EMPTY_DIRS="${CLEAN_EMPTY_DIRS:-1}"        
DEST_MIN_FREE="${DEST_MIN_FREE:-0}"              

LOG_FILE="${LOG_FILE:-/var/log/riviera_space_sweeper_rsync.log}" 
LOCK_FILE="/var/run/riviera_space_sweeper_rsync.lock"            
DRY_RUN="${DRY_RUN:-0}"                           

# ==========【优先级降低】==========
command -v ionice >/dev/null 2>&1 && ionice -c2 -n7 -p $$ >/dev/null 2>&1 || true
renice +15 -p $$ >/dev/null 2>&1 || true

# ==========【通用与通知函数】==========
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

# 钉钉通知发送函数
send_dingtalk_msg(){
  [ "$ENABLE_DINGTALK" -ne 1 ] && return 0
  local title="$1"
  local text="$2"
  
  local token_res=$(curl -s -X POST "https://api.dingtalk.com/v1.0/oauth2/accessToken" \
    -H "Content-Type: application/json" \
    -d "{\"appKey\":\"${DING_APP_KEY}\",\"appSecret\":\"${DING_APP_SECRET}\"}")
  local access_token=$(echo "$token_res" | grep -o '"accessToken":"[^"]*' | awk -F'"' '{print $4}')
  
  if [ -z "$access_token" ]; then
    log "钉钉告警失败: 无法获取 Access Token。"
    return 1
  fi
  
  local json_safe_msg=$(echo -n "$text" | sed 's/\\n/\\\\n/g')
  
  curl -s -X POST "https://api.dingtalk.com/v1.0/robot/oToMessages/batchSend" \
    -H "x-acs-dingtalk-access-token: ${access_token}" \
    -H "Content-Type: application/json" \
    -d "{\"robotCode\":\"${DING_APP_KEY}\",\"userIds\":[\"${DING_USER_ID}\"],\"msgKey\":\"sampleMarkdown\",\"msgParam\":\"{\\\"title\\\":\\\"${title}\\\",\\\"text\\\":\\\"${json_safe_msg}\\\"}\"}" >/dev/null
}

# 错误中断并发送告警
fail(){ 
  local err_msg="$*"
  log "ERROR: $err_msg"
  send_dingtalk_msg "❌ ${SITE_TAG} 搬运异常" "### 🚨 录像搬运脚本运行出错\n\n🌐 **节点**: ${SITE_TAG}\n\n**错误详情**:\n- ${err_msg}\n\n---\n⏱️ 时间: $(date '+%Y-%m-%d %H:%M:%S')"
  exit 1 
}

# 新增：无搬运时（空间充足/无文件/全失败）的巡检报告并退出
report_no_move_and_exit(){
  local reason="$1"
  local cur_free="$(free_kb)"
  local formatted_free="$(awk -v k="$cur_free" 'BEGIN{printf "%.2fGB",k/1024/1024}')"
  log "未执行搬运: $reason"
  
  if [ "$DRY_RUN" -eq 0 ]; then
    local notify_msg="### ℹ️ ${SITE_TAG} 空间巡检报告\n\n"
    notify_msg="${notify_msg}- **巡检结果**: 未发生文件搬运\n"
    notify_msg="${notify_msg}- **情况说明**: ${reason}\n"
    notify_msg="${notify_msg}- **当前剩余空间**: ${formatted_free}\n"
    notify_msg="${notify_msg}- **启动低水位**: ${THRESHOLD}\n"
    notify_msg="${notify_msg}\n---\n⏱️ 时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    send_dingtalk_msg "ℹ️ ${SITE_TAG} 巡检正常" "$notify_msg"
  fi
  exit 0
}

need_cmd(){ command -v "$1" >/dev/null 2>&1 || fail "缺少必需命令：$1"; }

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

free_kb(){ df -Pk "$VOLUME_PATH" 2>/dev/null | awk 'NR==2{print $4}'; }       
dest_free_kb(){ df -Pk "$MOUNT_POINT" 2>/dev/null | awk 'NR==2{print $4}'; } 

declare -a EXT_ARGS=()
build_ext_args(){
  EXT_ARGS=()
  local IFS=',' e
  for e in $1; do
    e="${e//[[:space:]]/}"          
    [[ -z "$e" ]] && continue
    EXT_ARGS+=(-iname "*.${e}")     
    EXT_ARGS+=(-o)                  
  done
  (( ${#EXT_ARGS[@]} > 0 )) && unset 'EXT_ARGS[${#EXT_ARGS[@]}-1]'  
}

# ==========【解析参数】==========
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
    -h|--help)      exit 0;;
    *) log "忽略未知参数：$1"; shift;;
  esac
done

# ==========【前置检查与锁】==========
need_cmd df; need_cmd find; need_cmd rsync; need_cmd mount; need_cmd awk; need_cmd sort; need_cmd wc; need_cmd stat
[ -d "$VOLUME_PATH" ] || fail "卷不存在：$VOLUME_PATH"
[ -d "$SRC_DIR" ]     || fail "源目录不存在：$SRC_DIR"
mkdir -p "$MOUNT_POINT" "$(dirname "$LOG_FILE")" || true

cleanup_lock(){ [ -n "${_LOCK_MODE:-}" ] && [ "$_LOCK_MODE" = "noclobber" ] && rm -f "$LOCK_FILE" || true; }
trap 'cleanup_lock' EXIT INT TERM

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE" || fail "无法创建锁文件：$LOCK_FILE"
  flock -n 9 || { log "已有实例在运行，退出。"; exit 0; }   
  _LOCK_MODE="flock"
else
  ( set -o noclobber; : > "$LOCK_FILE" ) 2>/dev/null || { log "已有实例在运行，退出。"; exit 0; }
  _LOCK_MODE="noclobber"
fi

# ==========【NFS 挂载】==========
ensure_mount(){
  grep -qs " $MOUNT_POINT " /proc/mounts && return 0
  log "NFS 未挂载，尝试 v3：$NFS_SERVER:$NFS_EXPORT -> $MOUNT_POINT"
  mount -t nfs -o "$NFS_OPTS" "$NFS_SERVER:$NFS_EXPORT" "$MOUNT_POINT" && { log "挂载成功（v3）"; return 0; }
  log "v3 失败，尝试 v4…"
  mount -t nfs -o rw,vers=4 "$NFS_SERVER:$NFS_EXPORT" "$MOUNT_POINT" && { log "挂载成功（v4）"; return 0; }
  fail "NFS 挂载失败，请检查 exportfs/权限/路径/防火墙"
}
ensure_mount

DST_DIR="$MOUNT_POINT/$SITE_TAG"
mkdir -p "$DST_DIR" || fail "无法创建目录：$DST_DIR"

# ==========【阈值计算】==========
THRESHOLD_KB="$(to_kb "$THRESHOLD")"
if [ -z "${RECOVER_TARGET:-}" ] || [ "$RECOVER_TARGET" = "0" ]; then
  RECOVER_TARGET_KB="$THRESHOLD_KB"   
else
  RECOVER_TARGET_KB="$(to_kb "$RECOVER_TARGET")"
  if [ "$RECOVER_TARGET_KB" -lt "$THRESHOLD_KB" ]; then
    log "注意：恢复目标($RECOVER_TARGET) < 启动阈值($THRESHOLD)，自动对齐为启动阈值。"
    RECOVER_TARGET_KB="$THRESHOLD_KB"
  fi
fi

CUR_FREE_KB="$(free_kb)"; [ -n "$CUR_FREE_KB" ] || fail "df 读取失败"
log "卷=$VOLUME_PATH；当前可用=$(awk -v k="$CUR_FREE_KB" 'BEGIN{printf "%.2fGB",k/1024/1024}')；启动阈值=$THRESHOLD"

# 核心修改点 1：可用空间充足时，发送巡检报告并退出
if [ "$CUR_FREE_KB" -ge "$THRESHOLD_KB" ]; then
  report_no_move_and_exit "当前空间充足，未跌破启动阈值"
fi

if [ -n "${DEST_MIN_FREE:-}" ] && [ "$DEST_MIN_FREE" != "0" ]; then
  DEST_MIN_FREE_KB="$(to_kb "$DEST_MIN_FREE")"
  CUR_DEST_FREE_KB="$(dest_free_kb || true)"
  [ -z "$CUR_DEST_FREE_KB" ] && fail "无法读取目标挂载点可用空间"
  if [ "$CUR_DEST_FREE_KB" -lt "$DEST_MIN_FREE_KB" ]; then
    fail "目标端可用空间低于保底(${DEST_MIN_FREE})，暂停本次搬运。"
  fi
fi

# ==========【生成候选清单】==========
TMP_LIST="$(mktemp -t rsync_sweep.XXXXXX)" || fail "mktemp 失败"
trap 'rm -f "$TMP_LIST"; cleanup_lock' EXIT INT TERM
build_ext_args "$EXTS"

if find / -maxdepth 0 -printf '' >/dev/null 2>&1; then
  if (( ${#EXT_ARGS[@]} > 0 )); then
    find "$SRC_DIR" -type f -mmin +"$MIN_AGE_MIN" \( "${EXT_ARGS[@]}" \) -printf '%T@\t%p\n' | sort -n -k1,1 > "$TMP_LIST"
  else
    find "$SRC_DIR" -type f -mmin +"$MIN_AGE_MIN" -printf '%T@\t%p\n' | sort -n -k1,1 > "$TMP_LIST"
  fi
else
  if (( ${#EXT_ARGS[@]} > 0 )); then
    find "$SRC_DIR" -type f -mmin +"$MIN_AGE_MIN" \( "${EXT_ARGS[@]}" \) -print0 | xargs -0 -I{} sh -c 'printf "%s\t%s\n" "$(stat -c %Y "{}")" "{}"' | sort -n -k1,1 > "$TMP_LIST"
  else
    find "$SRC_DIR" -type f -mmin +"$MIN_AGE_MIN" -print0 | xargs -0 -I{} sh -c 'printf "%s\t%s\n" "$(stat -c %Y "{}")" "{}"' | sort -n -k1,1 > "$TMP_LIST"
  fi
fi

CNT="$(wc -l < "$TMP_LIST" | awk '{print $1}')"

# 核心修改点 2：满足条件但无可移动文件时，发送巡检报告并退出
[ "$CNT" -eq 0 ] && report_no_move_and_exit "空间已超阈值，但未找到满足存放时长等条件的可移动文件"

log "候选文件数：$CNT"

# ==========【执行 rsync 搬运】==========
RSYNC_ARGS=(
  -rltD --no-owner --no-group
  --partial --inplace --remove-source-files
  --info=stats2,progress2
  --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r
)
[ "$BWLIMIT" != "0" ] && RSYNC_ARGS+=(--bwlimit="$BWLIMIT")
[ "$DRY_RUN" -eq 1 ] && RSYNC_ARGS+=(--dry-run)

moved=0
while IFS=$'\t' read -r _ts path; do
  CUR_FREE_KB="$(free_kb)"
  [ "$CUR_FREE_KB" -ge "$RECOVER_TARGET_KB" ] && { log "已达恢复目标，停止搬运。"; break; }

  SRC_SIZE="$(stat -c %s -- "$path" 2>/dev/null || echo 0)"
  rel="${path#$SRC_DIR/}"
  target_dir="$DST_DIR/$(dirname "$rel")"
  target_path="$DST_DIR/$rel"
  mkdir -p "$target_dir" || { log "创建目录失败：$target_dir"; continue; }

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN 将移动：$path -> $target_path"
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
      elif [ -f "$target_path" ] && [ "$SRC_SIZE" -gt 0 ]; then
        DST_SIZE="$(stat -c %s -- "$target_path" 2>/dev/null || echo 0)"
        if [ "$DST_SIZE" -eq "$SRC_SIZE" ]; then
          ok=1
        fi
      fi

      [ $ok -eq 1 ] && break
      sleep 10; try=$((try+1))
    done

    [ $ok -ne 1 ] && { log "放弃：$path"; continue; }
  fi

  moved=$((moved+1))
  if [ "$MAX_FILES_PER_RUN" -gt 0 ] && [ "$moved" -ge "$MAX_FILES_PER_RUN" ]; then
    break
  fi
done < "$TMP_LIST"

# ==========【清理空目录】==========
if [ "$CLEAN_EMPTY_DIRS" -eq 1 ]; then
  find "$SRC_DIR" -type d -empty -delete 2>/dev/null || true
fi

# ==========【收尾与钉钉汇总】==========
CUR_FREE_KB="$(free_kb)"
formatted_free="$(awk -v k="$CUR_FREE_KB" 'BEGIN{printf "%.2fGB",k/1024/1024}')"
log "本次移动：$moved；当前可用：$formatted_free"

# 核心修改点 3：根据搬运数量执行不同通知
if [ "$DRY_RUN" -eq 0 ]; then
  if [ "$moved" -gt 0 ]; then
    # 成功搬运通知
    notify_msg="### ✅ ${SITE_TAG} 录像搬运完成\n\n"
    notify_msg="${notify_msg}- **成功转移文件数**: ${moved}\n"
    notify_msg="${notify_msg}- **当前剩余空间**: ${formatted_free}\n"
    notify_msg="${notify_msg}- **启动低水位**: ${THRESHOLD}\n"
    
    if [ "$CUR_FREE_KB" -lt "$RECOVER_TARGET_KB" ]; then
      notify_msg="${notify_msg}\n⚠️ *注: 受限于文件数量上限或候选文件不足，本次尚未达到高水位目标。*\n"
    fi
    notify_msg="${notify_msg}\n---\n⏱️ 结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    
    send_dingtalk_msg "✅ ${SITE_TAG} 搬运成功" "$notify_msg"
  else
    # 执行了流程但 0 成功
    report_no_move_and_exit "执行了搬运流程，但没有文件成功转移（可能由于网络原因放弃）"
  fi
fi

exit 0
