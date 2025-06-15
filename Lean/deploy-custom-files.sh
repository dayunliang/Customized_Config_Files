#!/bin/bash
# ===========================================================================
# Lean OpenWrt 定制文件一键部署脚本（自动备份+集中展示备份清单）
# ---------------------------------------------------------------------------
# 1. 支持分发多个自定义脚本/配置到指定目录（自定义文件在你GitHub仓库下）
# 2. 如果目标目录下有同名文件，将自动先做一次 .bak.时间戳 备份
# 3. 部署结束后集中展示本次所有自动备份的文件清单，方便管理/回滚
# 4. 支持脚本多次反复运行、扩展，适合运维、协作
# ===========================================================================

set -e  # 只要有一条命令失败，立即退出脚本，防止脏环境

# ---------------------------------------------------------------------------
# 1. 基本变量定义
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/dayunliang/Customized_Config_Files.git"  # 你的自定义仓库地址
TMP_DIR=$(mktemp -d)   # 用于临时clone仓库，保证主目录干净
TS=$(date +%Y%m%d-%H%M%S)   # 时间戳，用于备份文件名防止覆盖
declare -a BACKUP_LIST      # 声明一个数组用于收集所有被备份的文件路径

# ---------------------------------------------------------------------------
# 2. 克隆你的定制文件仓库到临时目录
# ---------------------------------------------------------------------------
echo "1. 克隆自定义文件仓库到临时目录 $TMP_DIR ..."
git clone --depth=1 "$REPO_URL" "$TMP_DIR"

# ---------------------------------------------------------------------------
# 3. 带自动备份的文件复制函数
#    - src：源文件（你的仓库 Lean/ 目录下）
#    - dst：目标路径（Lean OpenWrt 源码实际目录）
#    - 步骤：
#        a) 源文件不存在则跳过
#        b) 目标文件已存在，先自动备份（加 .bak.时间戳 后缀），收集路径到数组
#        c) 然后覆盖复制
# ---------------------------------------------------------------------------
safe_cp() {
    src="$1"
    dst="$2"
    if [ ! -f "$src" ]; then
        echo "  [警告] 未找到自定义源文件 $src，跳过。"
        return 0
    fi
    if [ -f "$dst" ]; then
        backup_name="$dst.bak.$TS"
        cp -v "$dst" "$backup_name"
        BACKUP_LIST+=("$backup_name")  # 收集被备份的文件路径到数组
    fi
    cp -vf "$src" "$dst"
}

# ---------------------------------------------------------------------------
# 4. 依次分发所有定制文件
#    - 每一步都有说明实际用处和放置目录
# ---------------------------------------------------------------------------

echo "2. 分发自定义文件到指定目录..."

# 4.1 feeds.conf.default (feeds 源配置，主目录)
safe_cp "$TMP_DIR/Lean/feeds.conf.default" "./feeds.conf.default"

# 4.2 zzz-default-settings (默认配置脚本，编译期应用)
mkdir -p ./package/lean/default-settings/files
safe_cp "$TMP_DIR/Lean/zzz-default-settings" "./package/lean/default-settings/files/zzz-default-settings"

# 4.3 back-route 相关自定义脚本（OpenWrt /usr/bin/ 目录）
mkdir -p ./files/usr/bin
safe_cp "$TMP_DIR/Lean/back-route-checkenv.sh" "./files/usr/bin/back-route-checkenv.sh"
safe_cp "$TMP_DIR/Lean/back-route-complete.sh" "./files/usr/bin/back-route-complete.sh"
safe_cp "$TMP_DIR/Lean/back-route-cron.sh" "./files/usr/bin/back-route-cron.sh"
chmod +x ./files/usr/bin/back-route-*.sh  # 确保所有自定义脚本具备执行权限

# 4.4 IPsec 配置文件（/etc/ 目录）
mkdir -p ./files/etc
safe_cp "$TMP_DIR/Lean/ipsec.conf" "./files/etc/ipsec.conf"
safe_cp "$TMP_DIR/Lean/ipsec.secrets" "./files/etc/ipsec.secrets"

# 4.5 luci-app-ipsec-server 配置文件（如有，/etc/config/ 目录）
if [ -f "$TMP_DIR/Lean/luci-app-ipsec-server" ]; then
    mkdir -p ./files/etc/config
    safe_cp "$TMP_DIR/Lean/luci-app-ipsec-server" "./files/etc/config/luci-app-ipsec-server"
fi

# 4.6 crontab 定时任务 root 文件（/etc/crontabs/root，OpenWrt root 用户定时）
mkdir -p ./files/etc/crontabs
safe_cp "$TMP_DIR/Lean/root" "./files/etc/crontabs/root"

# ---------------------------------------------------------------------------
# 5. 清理临时 clone 目录，节省空间
# ---------------------------------------------------------------------------
echo "3. 清理临时目录 $TMP_DIR"
rm -rf "$TMP_DIR"

# ---------------------------------------------------------------------------
# 6. 集中输出所有本次被自动备份的文件清单
#    - 便于你一眼看到有哪些原文件被替换、备份在哪里
#    - 若没有备份，也给出明确提示
# ---------------------------------------------------------------------------
if [ ${#BACKUP_LIST[@]} -gt 0 ]; then
    echo
    echo "======================================================="
    echo "本次操作已自动备份的原有文件清单如下："
    for f in "${BACKUP_LIST[@]}"; do
        echo "  $f"
    done
    echo "如需还原原文件，请将上述 .bak.时间戳 文件复制覆盖回原名即可。"
    echo "======================================================="
else
    echo
    echo "本次未检测到需要备份的已有同名文件，无备份操作。"
fi

# ---------------------------------------------------------------------------
# 7. 脚本完成提示
# ---------------------------------------------------------------------------
echo
echo "所有自定义文件已安全分发并自动备份到对应目录，部署完毕。"
