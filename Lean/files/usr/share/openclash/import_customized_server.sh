#!/bin/sh
# ------------------------------------------------------------
# import_customized_server.sh (v11: authoritative sync)
# ------------------------------------------------------------
# 你的新逻辑（最终实现）：
# 1) openclash 中 server 若与 customized_server 同名 => 直接用 customized_server 覆盖
#    （实现方式：删除 openclash 中该 name 的所有同名段，再从 customized_server 重建 1 条）
# 2) 若 openclash 中 manual='1' 的 server 在 customized_server 中没有同名 => 删除该段
# 3) 复制（补齐）customized_server 中所有 server 到 openclash（缺的新增；同名已在步骤1覆盖）
#
# 结果：
# - customized_server 中出现的 name：openclash 最终只保留 1 条，且内容与 customized_server 一致
# - openclash 中非 manual=1 的订阅节点：只要 name 不与 customized_server 冲突，保留不动
# - openclash 中 manual=1 的“垃圾手工节点”：若不在 customized_server 中，全部删除
# ------------------------------------------------------------

LOG="/tmp/openclash_customized_import.log"
NOW() { date "+%F %T"; }
log() { echo "$(NOW) [customized_server] $*" >> "$LOG"; }

DIR="/usr/share/openclash"
SRC="$DIR/customized_server"
MAP="/tmp/customized_server_map.$$"

cleanup_tmp() {
  rm -f "$MAP" 2>/dev/null
}
trap cleanup_tmp EXIT

trim_ws() {
  printf "%s" "$1" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//"
}

strip_one_quote_pair() {
  v="$1"
  v="$(printf "%s" "$v" | tr -d '\r')"
  case "$v" in
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  v="$(trim_ws "$v")"
  printf "%s" "$v"
}

uci_list_items() {
  raw="$1"
  raw="$(printf "%s" "$raw" | tr -d '\r')"
  printf "%s" "$raw" | grep -o "'[^']*'" 2>/dev/null | sed "s/^'//;s/'$//"
}

# 列出 openclash 的所有 servers 段 section id（cfgxxxx）
all_openclash_server_secs() {
  uci -q show openclash 2>/dev/null | sed -n "s/^openclash\.\([^.]*\)=servers$/\1/p"
}

# 列出 openclash 中 manual=1 的 servers 段 section id
manual1_openclash_server_secs() {
  uci -q show openclash 2>/dev/null | sed -n "s/^openclash\.\([^.]*\)\.manual='1'$/\1/p" | sort -u
}

# customized_server: name -> section
find_custom_sec_by_name() {
  _n="$1"
  awk -F '\t' -v n="$_n" '$1==n {print $2; exit}' "$MAP" 2>/dev/null
}

# openclash: 找到所有同名 section（不限 manual）
find_openclash_secs_by_name() {
  _n="$1"
  for _sec in $(all_openclash_server_secs); do
    _name="$(uci -q get openclash."$_sec".name 2>/dev/null)"
    _name="$(strip_one_quote_pair "$_name")"
    [ -n "$_name" ] || continue
    [ "$_name" = "$_n" ] && printf "%s\n" "$_sec"
  done
}

# 用 customized_server 的某段创建一个 openclash servers 段（完整写入）
create_openclash_from_custom() {
  _custom_sec="$1"
  _name="$2"

  NEW="$(uci -q add openclash servers)"
  [ -n "$NEW" ] || { log "ERROR: failed to add openclash servers for name=$_name"; return 1; }

  # name 固定写入
  uci -q set openclash."$NEW".name="$_name"

  # 其余字段完全从 customized_server 复制
  uci -c "$DIR" show customized_server."$_custom_sec" 2>/dev/null | while IFS= read -r LINE; do
    LEFT="${LINE%%=*}"
    RAW="${LINE#*=}"
    KEY="${LEFT##*.}"

    # 跳过 header
    if [ "$RAW" = "servers" ]; then
      continue
    fi
    # name 已写
    [ "$KEY" = "name" ] && continue

    # groups/alpn 强制 list（兼容多个值）
    if [ "$KEY" = "groups" ] || [ "$KEY" = "alpn" ]; then
      uci -q delete openclash."$NEW"."$KEY" 2>/dev/null
      if printf "%s" "$RAW" | grep -q "'"; then
        uci_list_items "$RAW" | while IFS= read -r V; do
          V="$(strip_one_quote_pair "$V")"
          [ -n "$V" ] && uci -q add_list openclash."$NEW"."$KEY"="$V"
        done
      else
        V="$(strip_one_quote_pair "$RAW")"
        [ -n "$V" ] && uci -q add_list openclash."$NEW"."$KEY"="$V"
      fi
      continue
    fi

    # 其它字段：多值按 list，否则按 option
    if printf "%s" "$RAW" | grep -q "'[^']*' '"; then
      uci -q delete openclash."$NEW"."$KEY" 2>/dev/null
      uci_list_items "$RAW" | while IFS= read -r V; do
        V="$(strip_one_quote_pair "$V")"
        [ -n "$V" ] && uci -q add_list openclash."$NEW"."$KEY"="$V"
      done
    else
      V="$(strip_one_quote_pair "$RAW")"
      uci -q set openclash."$NEW"."$KEY"="$V"
    fi
  done

  log "created openclash section=$NEW for name=$_name (from customized_server.$_custom_sec)"
  return 0
}

# 强制覆盖：删除 openclash 中该 name 的所有同名段，然后按 customized_server 重建 1 条
force_overwrite_name_from_custom() {
  _name="$1"
  _csec="$2"

  # 删掉 openclash 所有同名段（订阅/手工一并清）
  _found=0
  for _sec in $(find_openclash_secs_by_name "$_name"); do
    _found=1
    log "overwrite: delete openclash.$_sec name=$_name"
    uci -q delete openclash."$_sec" 2>/dev/null
  done

  # 重建一条（无论之前是否存在）
  create_openclash_from_custom "$_csec" "$_name"

  if [ "$_found" -eq 0 ]; then
    log "overwrite: name=$_name not found in openclash before, created new one"
  fi
}

# -------------------- main --------------------

log "using customized_server: $SRC"
[ -f "$SRC" ] || { log "customized_server not found, skip"; exit 0; }

uci -c "$DIR" show customized_server >/dev/null 2>&1 || {
  log "ERROR: uci cannot parse $SRC"
  exit 1
}

# 生成 customized_server name->section 映射（全量，不筛 manual）
: > "$MAP"
CUSTOM_SECS="$(uci -c "$DIR" show customized_server 2>/dev/null | \
  sed -n "s/^customized_server\.\(@servers\[[0-9]\+\]\)=servers$/\1/p")"

for CSEC in $CUSTOM_SECS; do
  NAME="$(uci -c "$DIR" -q get customized_server."$CSEC".name 2>/dev/null)"
  NAME="$(strip_one_quote_pair "$NAME")"
  [ -n "$NAME" ] || continue

  # customized_server 内同名：保留第一条
  if awk -F '\t' -v n="$NAME" '$1==n {found=1} END{exit found?0:1}' "$MAP" 2>/dev/null; then
    log "WARN: duplicated name in customized_server: $NAME (keep first)"
    continue
  fi

  printf "%s\t%s\n" "$NAME" "$CSEC" >> "$MAP"
done

MAP_COUNT="$(wc -l < "$MAP" 2>/dev/null | tr -d ' ')"
log "customized_server mapped servers count: ${MAP_COUNT:-0}"

# ------------------------------------------------------------
# Step 1) openclash 中只要 name 在 customized_server 存在 => 直接覆盖（强制以 customized 为准）
# 做法：遍历 openclash 的所有 servers，遇到同名就“整组删+重建”
# 为避免重复重建同一个 name，用一个临时集合做去重执行
# ------------------------------------------------------------
_DONE="/tmp/overwrite_done.$$"
: > "$_DONE"

for OSEC in $(all_openclash_server_secs); do
  ONAME="$(uci -q get openclash."$OSEC".name 2>/dev/null)"
  ONAME="$(strip_one_quote_pair "$ONAME")"
  [ -n "$ONAME" ] || continue

  CSEC="$(find_custom_sec_by_name "$ONAME")"
  [ -n "$CSEC" ] || continue

  # 同一个 name 只执行一次覆盖
  if grep -Fxq "$ONAME" "$_DONE" 2>/dev/null; then
    continue
  fi
  printf "%s\n" "$ONAME" >> "$_DONE"

  log "step1: found same name in openclash & customized_server => force overwrite name=$ONAME"
  force_overwrite_name_from_custom "$ONAME" "$CSEC"
done

rm -f "$_DONE" 2>/dev/null

# ------------------------------------------------------------
# Step 2 & 3) 清理 openclash 中 manual=1 但 customized_server 不存在同名的段：删除
# ------------------------------------------------------------
for MSEC in $(manual1_openclash_server_secs); do
  MNAME="$(uci -q get openclash."$MSEC".name 2>/dev/null)"
  MNAME="$(strip_one_quote_pair "$MNAME")"
  [ -n "$MNAME" ] || continue

  CSEC="$(find_custom_sec_by_name "$MNAME")"
  if [ -z "$CSEC" ]; then
    log "step2/3: delete openclash.$MSEC (manual=1) name=$MNAME (not in customized_server)"
    uci -q delete openclash."$MSEC" 2>/dev/null
  fi
done

# ------------------------------------------------------------
# Step 3) 复制 customized_server 中所有 server（补齐缺失的）
# 做法：遍历 customized_server map，若 openclash 中找不到该 name，则创建
# ------------------------------------------------------------
awk -F '\t' '{print $1 "\t" $2}' "$MAP" 2>/dev/null | while IFS="$(printf '\t')" read -r N CSEC; do
  [ -n "$N" ] || continue
  [ -n "$CSEC" ] || continue

  # 如果 openclash 里不存在该 name，则新增
  if [ -z "$(find_openclash_secs_by_name "$N" | head -n 1)" ]; then
    log "step3: add missing name=$N from customized_server.$CSEC"
    create_openclash_from_custom "$CSEC" "$N"
  fi
done

uci -q commit openclash
log "commit done"
exit 0
