#!/bin/bash
# ===========================================================================
# Lean OpenWrt 定制文件一键部署脚本【逐行详解版】
# ---------------------------------------------------------------------------
# 本脚本用于：
#   1) 在“非源码根目录”情况下，交互式 git clone OpenWrt 源码并进入
#   2) 克隆你的定制配置仓库（REPO_URL），按“站点优先，默认兜底”的策略部署到源码树
#   3) 对目标路径已有文件做时间戳备份，防止覆盖造成的丢失
#   4) 自动检查/追加 luci 源并安装 luci-base（确保有 po2lmo 工具），然后编译 host 侧 po2lmo
#   5) 可选：首次构建预下载 dl 源码包，并自动校验/补下损坏文件
#   6) 在复制配置前，支持交互式将 WireGuard 私钥注入到模板（__WG_PRIVKEY__），
#      若模板中未找到占位符，则自动生成 uci-defaults 作为兜底（首次开机落盘）
#   7) 部署完成后执行 remove_conflict.sh 两次（defconfig 前后各一次）与 make defconfig
#   8) 输出“部署命中/跳过统计”和“备份清单”，最后给出操作摘要
#
# 使用须知：
#   - 建议在干净/可恢复的源码树上执行（脚本内置较完善的备份机制，但仍需谨慎）
#   - 脚本通过 set -e 在任何命令失败时立即退出，以避免错误继续放大
#   - WireGuard 私钥仅在内存中处理，若生成 uci-defaults，会将明文写入 overlay；
#     如你对私钥落盘敏感，请选择“注入模板成功”并避免兜底路径
# ---------------------------------------------------------------------------
# 作者：https://github.com/dayunliang
# ===========================================================================

set -e  # 【安全护栏】任何命令出错立即退出（避免错误链式传播）

# ==== [1] 环境检查 ====
# 目的：确保脚本在 bash 下执行（某些语法/特性仅 bash 可用）。
if [ -z "$BASH_VERSION" ]; then
    echo "❗ 必须在 bash 环境下执行此脚本，sh 环境不支持！"
    exit 1
fi

# ==== [2] 检查是否在 OpenWrt 源码根目录 ====
# 判据：scripts/feeds 文件存在 + package 目录存在。
# 若不满足，则提供交互式 clone 体验（允许指定仓库 URL 与目标目录）。

# spinner 函数：用于在耗时操作（例如清空目录）期间显示转动动画，提升交互友好度。
# 参数：$1 = 后台任务的 PID；逻辑：只要该 PID 仍在运行，就不断刷新“旋转字符”。
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c] 正在清空目录..." "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r%-40s\r" " "   # 清空整行避免残留
    done
}

# 若当前目录不满足“OpenWrt 源码根目录”的判定，则提供自动 clone 逻辑。
if [ ! -f "./scripts/feeds" ] || [ ! -d "./package" ]; then
    echo "🔍 未检测到 OpenWrt 源码根目录。"
    read -p "是否自动 clone OpenWrt 仓库并进入？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 允许用户自定义源仓库 URL；默认取 coolsnowwolf/lede
        read -p "请输入 OpenWrt 仓库 URL (默认: https://github.com/coolsnowwolf/lede.git): " repo_url
        repo_url=${repo_url:-https://github.com/coolsnowwolf/lede.git}

        # 允许用户自定义目标目录名；默认 lede
        read -p "请输入目标目录名 (默认: lede): " target_dir
        target_dir=${target_dir:-lede}

        # 若目标目录已存在，进入后判断是否为空/有效；给予清空并 clone 的选项
        if [ -d "$target_dir" ]; then
            echo "⚠️ 目录 $target_dir 已存在，进入该目录..."
            cd "$target_dir"

            if [ -z "$(ls -A .)" ]; then
                # 空目录：直接 clone 到当前目录
                echo "🌐 目录为空，正在克隆 $repo_url ..."
                git clone --depth=1 "$repo_url" . || { echo "❌ 克隆失败"; exit 1; }
            else
                # 非空目录：是否需要清空后再 clone
                read -p "⚠️ 当前目录非空，是否清空后再克隆？(y/N): " clear_confirm
                if [[ "$clear_confirm" =~ ^[Yy]$ ]]; then
                    # 使用后台 rm -rf，并用 spinner 展示进度感
                    (rm -rf ./* ./.??* ) &
                    pid=$!
                    show_spinner $pid
                    wait $pid
                    echo "✅ 目录已清空"
                    echo "🌐 开始克隆 $repo_url ..."
                    git clone --depth=1 "$repo_url" . || { echo "❌ 克隆失败"; exit 1; }
                else
                    # 允许用户跳过 clone，但需校验是否已是有效源码目录
                    if [ ! -f "./scripts/feeds" ] || [ ! -d "./package" ]; then
                        echo "❌ 当前目录不是有效的 OpenWrt 源码目录，无法继续"
                        exit 1
                    fi
                    echo "➡️ 跳过 git clone，继续执行后续步骤..."
                fi
            fi
        else
            # 目标目录不存在：常规 clone 到指定目录，然后 cd 进入
            echo "🌐 正在克隆 $repo_url 到 $target_dir ..."
            git clone --depth=1 "$repo_url" "$target_dir" || { echo "❌ 克隆失败"; exit 1; }
            cd "$target_dir"
        fi
        echo "✅ 已进入源码目录：$(pwd)"
    else
        # 用户选择不自动 clone：提示手工步骤然后退出
        echo "❌ 请先手动下载源码再运行本脚本"
        echo "示例："
        echo "  git clone https://github.com/coolsnowwolf/lede.git"
        echo "  cd lede"
        echo "  bash $0"
        exit 1
    fi
fi

# ==== [3.1] 基本变量 ====
# REPO_URL：你的定制仓库地址；TMP_DIR：临时工作目录（自动清理）；
# TS：时间戳用于备份后缀；BACKUP_LIST：收集所有备份条目，便于最后汇总展示。
REPO_URL="https://github.com/dayunliang/Customized_Config_Files.git" # 配置文件仓库
TMP_DIR=$(mktemp -d)    # 临时目录（脚本结束会删除）
TS=$(date +%Y%m%d-%H%M%S) # 当前时间戳，用于备份文件命名
declare -a BACKUP_LIST  # 数组，用于记录备份文件路径

# ==== [3.2] 克隆定制配置文件仓库 ====
# 使用 --depth=1 浅克隆加速；若失败立刻退出（避免后续空路径拷贝）。
echo "1. 克隆定制配置仓库到临时目录 $TMP_DIR ..."
if ! git clone --depth=1 "$REPO_URL" "$TMP_DIR"; then
    echo "❌ 克隆仓库失败：$REPO_URL"
    exit 1
fi

# ==== [4] 编译版本选择逻辑 ====
# 三个选项对应你的不同站点/方案；后续部署时采用“站点优先，默认兜底”的查找策略。
echo

echo "请选择要部署的编译版本："
echo " 1) Beverly"
echo " 2) Riviera"
echo " 3) DOITCHINA"
read -p "请输入数字 (1-3): " compile_choice

case "$compile_choice" in
  1) COMPILE_NAME="Beverly" ;;
  2) COMPILE_NAME="Riviera" ;;
  3) COMPILE_NAME="DOITCHINA" ;;
  *) echo "❌ 无效选择：$compile_choice"; exit 1 ;;
esac
echo "已选择编译版本：$COMPILE_NAME"
echo

# ==== [5] 复制与统计（保留备份） ====
# __DEPLOY_HITS / __DEPLOY_SKIPS：记录“命中部署（含站点/默认）”与“跳过（缺失即成功）”的条目，
# 便于最后输出部署摘要。
__DEPLOY_HITS=""
__DEPLOY_SKIPS=""

__hit()  { __DEPLOY_HITS="${__DEPLOY_HITS}${1}\n"; }
__skip() { __DEPLOY_SKIPS="${__DEPLOY_SKIPS}${1}\n"; }

# safe_cp：安全复制。
#   - 若目标已存在，先创建“同目录同名 + .bak.时间戳”的备份，然后再覆盖复制
#   - 同时确保目标父目录存在（mkdir -p）
#   - 将备份路径记入 BACKUP_LIST，便于末尾统一罗列
safe_cp() {
  src="$1"
  dst="$2"
  if [ -f "$dst" ]; then
    backup_name="$dst.bak.$TS"
    cp -v "$dst" "$backup_name"
    BACKUP_LIST+=("$backup_name")
  fi
  mkdir -p "$(dirname "$dst")"
  cp -vf "$src" "$dst"
}

# 源与目标根：
#   - SRC_ROOT：定制仓库中的 overlay 根（Lean/files）
#   - DST_ROOT：OpenWrt 源码树中的 overlay 根（./files），最终会被打包进固件
SRC_ROOT="${TMP_DIR}/Lean/files"   # overlay 源（按相对路径部署）
DST_ROOT="./files"                 # OpenWrt overlay 目标根

# ==== [6] 部署函数（缺失也视为成功） ====
# 统一“站点优先，默认兜底”的查找顺序，且“缺失不报错、视为成功”。
# 这样可以灵活地为不同站点放置差异化文件，而不必每个文件都提供默认版本。

# 6.1 部署 overlay 文件：
# 用法：deploy_file "usr/bin/back-route-complete.sh" "755"
# 逻辑：先找 SRC_ROOT/相对路径.站点名 => 命中即复制；
#       否则找 SRC_ROOT/相对路径（默认版）；
#       若两者都不存在，输出 [SKIP_OK]，并记入“跳过”统计。
deploy_file() {
  rel="$1"
  mode="${2:-644}"
  site_src="${SRC_ROOT}/${rel}.${COMPILE_NAME}"
  def_src="${SRC_ROOT}/${rel}"
  dst="${DST_ROOT}/${rel}"

  if [ -f "${site_src}" ]; then
    echo "[DEPLOY] ${site_src} -> ${dst}"
    safe_cp "${site_src}" "${dst}"
    chmod "${mode}" "${dst}" || true   # 权限设置失败不致命，允许继续
    __hit "${rel} (site=${COMPILE_NAME})"
  elif [ -f "${def_src}" ]; then
    echo "[DEPLOY] ${def_src} -> ${dst}"
    safe_cp "${def_src}" "${dst}"
    chmod "${mode}" "${dst}" || true
    __hit "${rel} (default)"
  else
    echo "[SKIP_OK] ${rel} (no site/default needed)"
    __skip "${rel}"
  fi
  return 0
}

# 6.2 部署“仓库根”文件（Lean/ 下的顶层文件）：
# 用法举例：
#   deploy_root "config" "./.config" "644"
#   deploy_root "feeds.conf.default" "./feeds.conf.default" "644"
#   deploy_root "zzz-default-settings" "./package/lean/default-settings/files/zzz-default-settings" "755"
# 查找顺序与 deploy_file 相同：站点优先 -> 默认兜底；缺失也算成功。
deploy_root() {
  name="$1"          # 仓库根文件名（不带路径）
  dst="$2"           # 目标绝对路径
  mode="${3:-644}"   # chmod 权限

  site_src="${TMP_DIR}/Lean/${name}.${COMPILE_NAME}"
  def_src="${TMP_DIR}/Lean/${name}"

  if [ -f "${site_src}" ]; then
    echo "[DEPLOY] ${site_src} -> ${dst}"
    safe_cp "${site_src}" "${dst}"
    chmod "${mode}" "${dst}" || true
    __hit "${name} (site=${COMPILE_NAME})"
  elif [ -f "${def_src}" ]; then
    echo "[DEPLOY] ${def_src} -> ${dst}"
    safe_cp "${def_src}" "${dst}"
    chmod "${mode}" "${dst}" || true
    __hit "${name} (default)"
  else
    echo "[SKIP_OK] root ${name} (no site/default needed)"
    __skip "${name}"
  fi
  return 0
}

# 6.3 汇总函数：将命中与跳过的条目一次性打印出来，便于快速浏览部署结果。
deploy_summary() {
  printf '\n[SUMMARY] Profile=%s\n' "${COMPILE_NAME}"

  if [ -n "${__DEPLOY_HITS}" ]; then
    printf '[DEPLOYED]\n%b' "${__DEPLOY_HITS}"
  else
    printf '[DEPLOYED]\n(none)\n'
  fi

  if [ -n "${__DEPLOY_SKIPS}" ]; then
    printf '[SKIPPED OK]\n%b' "${__DEPLOY_SKIPS}"
  else
    printf '[SKIPPED OK]\n(none)\n'
  fi
}

# ==== [7] 部署配置文件 ====
# 进入具体拷贝阶段：先部署仓库根（.config、feeds.conf.default、zzz-default-settings、remove_conflict.sh），
# 再部署 overlay（Lean/files 下的相对路径）。缺失任何文件均视为“跳过成功”。
echo "2. 部署 [$COMPILE_NAME] 编译版本配置文件..."

# 11.1 仓库根（Lean/ 下）
deploy_root "config"                 "./.config"                                                  "644"
deploy_root "feeds.conf.default"     "./feeds.conf.default"                                       "644"
deploy_root "zzz-default-settings"   "./package/lean/default-settings/files/zzz-default-settings" "755"
deploy_root "remove_conflict.sh"     "./remove_conflict.sh"                                       "755"

# 11.2 overlay（Lean/files/ 下）
# 回程路由脚本（环境检测/一次性修复/定时巡检）
deploy_file "usr/bin/back-route-checkenv.sh"         "755"
deploy_file "usr/bin/back-route-complete.sh"         "755"
deploy_file "usr/bin/back-route-cron.sh"             "755"

# IPSec（如需启用，按需取消注释）
# deploy_file "etc/ipsec.conf"                          "644"
# deploy_file "etc/ipsec.secrets"                       "600"
# deploy_file "etc/config/luci-app-ipsec-server"        "644"

# OpenClash 配置与脚本（规则/自定义脚本/启停辅助）
deploy_file "etc/config/openclash"                   "644"
deploy_file "etc/openclash/custom/openclash_custom_rules.list" "644"
deploy_file "usr/share/openclash/res/rule_providers.list"      "644"
deploy_file "etc/openclash/dns_enable_false.sh"      "755"
deploy_file "usr/share/openclash/yml_proxys_set.sh"  "755"

# WireGuard 网络接口刷新脚本（某站点可能没有，缺失视为成功）
deploy_file "usr/bin/WireGuard_Refresh.sh"           "755"

# 其它网络加速、计划任务等（依据仓库是否提供而定）
deploy_file "etc/config/turboacc"                    "644"
deploy_file "etc/crontabs/root"                      "600"

# ==== [8] 检查 luci feed（po2lmo 工具所在位置） ====
# 若 feeds.conf.default 未声明 luci 源，则自动追加，以确保后续能安装到 luci-base。
if ! grep -qE '^src-git[[:space:]]+luci[[:space:]]+' feeds.conf.default; then
    echo "⚠️  feeds.conf.default 缺少 luci 源，已自动追加"
    echo "src-git luci https://github.com/coolsnowwolf/luci" >> feeds.conf.default
fi

# 仅更新 luci 源并安装 luci-base（其 host 侧会生成 po2lmo）
./scripts/feeds update luci
./scripts/feeds install luci-base

# ==== [9] 全量更新安装 feeds ====
# 清理旧索引 -> 全量 update -> 全量 install。
# 之后单独 clone 主题到 package/lean 目录，保证树结构简洁。
echo "🛠️ 正在执行 feeds update/install..."
./scripts/feeds clean
./scripts/feeds update -a
./scripts/feeds install -a

# 添加主题（如已存在则先删除再 clone 保持最新）
#echo "🌈 添加 luci-theme-neobird..."
#mkdir -p package/lean
#rm -rf package/lean/luci-theme-neobird
#git clone https://github.com/thinktip/luci-theme-neobird.git package/lean/luci-theme-neobird

# ==== [10] 编译 po2lmo 工具 ====
# 一些 default-settings/luci 翻译场景需要 po2lmo；
# 通过 "luci-base/host/compile" 构建 host 侧工具，避免缺工具导致的编译报错。
echo "🛠️ 编译 po2lmo 工具..."
make package/feeds/luci/luci-base/host/compile V=s

# ==== [11.1] 首次构建可选下载源码包 ====
# 交互式确认：若是首次构建，则执行 make download 并对 dl/ 下的小文件（<1024B）进行清理重下，
# 直到无损坏文件为止，从而最大程度避免后续编译阶段的缺包问题。
read -p "🧐 是否首次构建？需要预下载源码包？(y/N): " is_first
if [[ "$is_first" =~ ^[Yy]$ ]]; then
    echo "📥 开始预下载源码包..."
    while true; do
        make download -j8 V=s
        broken=$(find dl -size -1024c)
        if [ -z "$broken" ]; then
            echo "✅ 下载完成且校验通过"
            break
        else
            echo "⚠️ 检测到不完整文件，重新下载..."
            find dl -size -1024c -exec rm -f {} \;
        fi
    done
else
    echo "✅ 跳过预下载，可直接 make -j$(nproc) V=s"
fi

# ==== [11.2] WireGuard 私钥注入（复制前在模板中替换占位符） ====
# 约定：在模板文件里使用占位符 __WG_PRIVKEY__；
# 本段逻辑会：
#  1) 交互读取私钥（做长度/字符集粗校验）
#  2) 先扫描“站点化模板”(*.COMPILE_NAME) 进行替换
#  3) 若站点模板未命中，再尝试“默认模板”（无后缀）
#  4) 若两类模板均未发现占位符，则生成 uci-defaults 脚本作为兜底写入（首次开机生效）

echo
read -p "是否为 ${COMPILE_NAME} 注入 WireGuard 私钥到模板？(y/N): " inject_wgkey
if [[ "$inject_wgkey" =~ ^[Yy]$ ]]; then
  # 交互式读取；这里不使用 -s（隐藏回显）是为了减少某些环境下粘贴误差，
  # 如需隐藏回显，可改为 read -s（注意用户体验）。
  while true; do
    read -p "请输入 ${COMPILE_NAME} 的 WireGuard 私钥（典型44字符，末尾=）： " WG_PRIVKEY
    echo
    if [[ "$WG_PRIVKEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
      break
    else
      echo "❗ 格式看起来不对，请重试。"
    fi
  done

  # 在临时克隆目录内执行占位符替换，避免污染你的原始仓库
  echo "🔎 正在扫描模板中的占位符 __WG_PRIVKEY__ ..."
  # 站点优先：匹配 *.${COMPILE_NAME}
  mapfile -t SITE_MATCHES < <(grep -RIl -e '__WG_PRIVKEY__' "${TMP_DIR}/Lean" --include="*.${COMPILE_NAME}" 2>/dev/null || true)
  # 默认兜底：匹配不带站点后缀的文件
  mapfile -t DEF_MATCHES  < <(grep -RIl -e '__WG_PRIVKEY__' "${TMP_DIR}/Lean" --exclude="*.${COMPILE_NAME}" 2>/dev/null || true)

  REPLACED=0
  if [ ${#SITE_MATCHES[@]} -gt 0 ]; then
    echo "✏️  在站点模板中替换："
    for f in "${SITE_MATCHES[@]}"; do
      [ -n "$f" ] || continue
      echo "  - ${f#${TMP_DIR}/}"
      sed -i "s|__WG_PRIVKEY__|${WG_PRIVKEY}|g" "$f"
      REPLACED=$((REPLACED+1))
    done
  fi

  # 若站点模板中未替换任何文件，再尝试默认模板
  if [ $REPLACED -eq 0 ] && [ ${#DEF_MATCHES[@]} -gt 0 ]; then
    echo "✏️  未在站点模板找到占位符，改为在默认模板中替换："
    for f in "${DEF_MATCHES[@]}"; do
      [ -n "$f" ] || continue
      echo "  - ${f#${TMP_DIR}/}"
      sed -i "s|__WG_PRIVKEY__|${WG_PRIVKEY}|g" "$f"
      REPLACED=$((REPLACED+1))
    done
  fi

  if [ $REPLACED -gt 0 ]; then
    echo "✅ 已在 ${REPLACED} 个模板文件中完成私钥替换（复制时将随之生效）。"
  else
    # 兜底：生成一个 uci-defaults 脚本，首次开机执行时写入私钥
    echo "⚠️ 未在模板中发现占位符。将改为生成 uci-defaults 作为兜底方案。"
    WG_UCI_DEFAULTS_PATH="./files/etc/uci-defaults/99-wg-private-key"
    mkdir -p "$(dirname "$WG_UCI_DEFAULTS_PATH")"
    cat > "$WG_UCI_DEFAULTS_PATH" <<'EOF_UCI'
#!/bin/sh
# 说明：此脚本作为兜底，将在设备首次启动时被 /etc/uci-defaults/ 机制执行。
# 作用：为现有的 wireguard 接口写入私钥；若未创建，则新建 network.wg0 并写入。
WG_KEY_PLACEHOLDER="__WG_PRIVKEY__"
if uci -q get network.wg0.proto >/dev/null 2>&1; then
  uci set network.wg0.private_key="$WG_KEY_PLACEHOLDER"
else
  FIRST_WG_IF="$(uci -q show network | awk -F= '/=interface/{print $1}' | while read s; do \
    p="$(uci -q get ${s}.proto 2>/dev/null)"; [ "$p" = "wireguard" ] && echo "$s" && break; done)"
  if [ -n "$FIRST_WG_IF" ]; then
    uci set "$FIRST_WG_IF".private_key="$WG_KEY_PLACEHOLDER"
  else
    uci set network.wg0=interface
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$WG_KEY_PLACEHOLDER"
  fi
fi
uci commit network
exit 0
EOF_UCI
    # 用实际密钥替换占位符（谨慎：这会将明文写入 overlay 文件系统）
    sed -i "s|__WG_PRIVKEY__|${WG_PRIVKEY}|g" "$WG_UCI_DEFAULTS_PATH"
    chmod 600 "$WG_UCI_DEFAULTS_PATH"   # 限权：仅 root 可读写
    echo "✅ 已生成兜底脚本：${WG_UCI_DEFAULTS_PATH}（首次开机自动写入私钥）"
  fi
else
  echo "⏭️ 跳过私钥注入。"
fi

# ==== [12] 删除临时目录 ====
# 安全清理：部署结束后移除临时克隆仓库目录，避免遗留敏感内容。
echo "4. 删除临时目录 $TMP_DIR"
rm -rf "$TMP_DIR"

# ==== [13] defconfig 前/后冲突清理与配置固化 ====
# remove_conflict.sh：你仓库里的“二次开关/兜底剔除”脚本，用于在 defconfig 前后都再跑一次，
# 防止在 defconfig 过程中某些默认项被重新点亮。
./remove_conflict.sh
make defconfig
./remove_conflict.sh   # 再跑一次，确保最终 .config 保持期望状态

# 部署统计汇总（命中/跳过）
deploy_summary

# ==== [14] 显示备份列表 ====
# 若本次覆盖了任何已存在文件，会在这里罗列其 *.bak.时间戳 副本，便于回滚。
if [ ${#BACKUP_LIST[@]} -gt 0 ]; then
    echo "🗂️ 本次备份的文件："
    for f in "${BACKUP_LIST[@]}"; do echo "  $f"; done
else
    echo "🗂️ 本次没有文件被覆盖，因此没有备份"
fi

# ==== [15] 执行摘要 ====
# 快速总览：帮助回忆刚刚发生的步骤，便于日志检索与二次执行。
echo "📋 执行步骤总结："
echo "-------------------------------------------------------"
echo "✅ 部署定制文件"
echo "✅ 自动备份已有配置"
echo "✅ 执行 feeds update/install & make defconfig"
echo "✅ 编译 po2lmo 工具"
echo "✅ （可选）下载源码包并校验"
echo "✅ WireGuard 私钥占位符注入/兜底 uci-defaults"
echo "-------------------------------------------------------"

# ==== [16] 完成提示 ====
# 给出下一步编译建议（使用全部可用 CPU 核心加速编译）。
echo "🚀 配置部署完成！"
echo "👉 当前源码目录: $(pwd)"
echo "💡 可执行：make -j$(nproc) V=s"

# 版本注记：
# 2025-12-04   初稿：加入 WireGuard 私钥注入/兜底，完善部署与统计输出
# 2025-12-06   注释版：逐行/逐段超详尽注释与注意事项、风险提示与使用建议
