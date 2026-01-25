#!/bin/sh
# ------------------------------------------------------------
# import_customized_server.sh
# ------------------------------------------------------------
# v5 fixes:
# - When dumping a section with `uci show customized_server.@servers[x]`,
#   UCI may output the header as `customized_server.cfgXXXX=servers`
#   (resolved section id), not `customized_server.@servers[x]=servers`.
#   v4 accidentally imported that header as a normal option, creating
#   junk keys like `cfg014a8f='servers'` inside openclash servers.
# - v5 skips ANY header line that ends with `=servers`.
#
# Other behavior:
# - Source: /usr/share/openclash/customized_server (UCI)
# - Target: /etc/config/openclash
# - Delete ALL existing openclash servers sections with same name, then re-create
# - groups/alpn always written as LIST (handles "key='a' 'b'" output)
# ------------------------------------------------------------

LOG="/tmp/openclash_customized_import.log"
NOW() { date "+%F %T"; }
log() { echo "$(NOW) [customized_server] $*" >> "$LOG"; }

DIR="/usr/share/openclash"
SRC="$DIR/customized_server"

strip_one_quote_pair() {
  v="$1"
  v="$(printf "%s" "$v" | tr -d '\r')"
  case "$v" in
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf "%s" "$v"
}

uci_list_items() {
  raw="$1"
  raw="$(printf "%s" "$raw" | tr -d '\r')"
  printf "%s" "$raw" | grep -o "'[^']*'" 2>/dev/null | sed "s/^'//;s/'$//"
}

log "using customized_server: $SRC"

[ -f "$SRC" ] || { log "customized_server not found, skip"; exit 0; }

uci -c "$DIR" show customized_server >/dev/null 2>&1 || {
  log "ERROR: uci cannot parse $SRC"
  exit 1
}

SECS="$(uci -c "$DIR" show customized_server 2>/dev/null | \
  sed -n "s/^customized_server\.\(@servers\[[0-9]\+\]\)=servers$/\1/p")"

[ -n "$SECS" ] || { log "no servers sections found, skip"; exit 0; }

count="$(printf "%s\n" "$SECS" | wc -l | tr -d ' ')"
log "found servers sections: $count"

for SEC in $SECS; do
  NAME_LINE="$(uci -c "$DIR" -q show customized_server."$SEC".name 2>/dev/null)"
  NAME_RAW="${NAME_LINE#*=}"
  NAME="$(strip_one_quote_pair "$NAME_RAW")"

  [ -n "$NAME" ] || { log "skip section=$SEC: empty name"; continue; }
  log "import name=$NAME section=$SEC"

  # Delete ALL existing openclash sections with same name
  uci -q show openclash 2>/dev/null | grep -F ".name='$NAME'" | while IFS= read -r L; do
    OLD_SEC="${L%%.name=*}"
    OLD_SEC="${OLD_SEC#openclash.}"
    [ -n "$OLD_SEC" ] && uci -q delete openclash."$OLD_SEC" 2>/dev/null
  done

  NEW="$(uci -q add openclash servers)"
  [ -n "$NEW" ] || { log "ERROR: failed to add openclash servers for name=$NAME"; continue; }

  uci -q set openclash."$NEW".name="$NAME"

  # Iterate all key/value lines for this section
  uci -c "$DIR" show customized_server."$SEC" 2>/dev/null | while IFS= read -r LINE; do
    LEFT="${LINE%%=*}"
    RAW="${LINE#*=}"
    KEY="${LEFT##*.}"

    # Skip any section header line like customized_server.cfgXXXX=servers
    if [ "$RAW" = "servers" ]; then
      continue
    fi

    [ "$KEY" = "name" ] && continue

    if [ "$KEY" = "groups" ] || [ "$KEY" = "alpn" ]; then
      uci -q delete openclash."$NEW"."$KEY" 2>/dev/null
      if printf "%s" "$RAW" | grep -q "'"; then
        uci_list_items "$RAW" | while IFS= read -r V; do
          [ -n "$V" ] && uci -q add_list openclash."$NEW"."$KEY"="$V"
        done
      else
        V="$(strip_one_quote_pair "$RAW")"
        [ -n "$V" ] && uci -q add_list openclash."$NEW"."$KEY"="$V"
      fi
      continue
    fi

    if printf "%s" "$RAW" | grep -q "'[^']*' '"; then
      uci -q delete openclash."$NEW"."$KEY" 2>/dev/null
      uci_list_items "$RAW" | while IFS= read -r V; do
        [ -n "$V" ] && uci -q add_list openclash."$NEW"."$KEY"="$V"
      done
    else
      V="$(strip_one_quote_pair "$RAW")"
      uci -q set openclash."$NEW"."$KEY"="$V"
    fi
  done

  log "created openclash section=$NEW for name=$NAME"
done

uci -q commit openclash
log "commit done"
exit 0
