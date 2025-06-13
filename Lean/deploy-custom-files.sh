#!/bin/bash
# ===========================================================================
# Lean OpenWrt 定制文件一键部署脚本（带自动备份）
# - 每次复制前自动检测目标是否有同名文件，有则自动备份
# - 最大限度保护已有配置
# - 支持增删定制文件，只需维护好仓库和本脚本
# - 适合开发、多人协作、批量部署等场景
# ===========================================================================

set -e  # 一旦脚本中有任何一步失败，立即终止执行，防止半成品状态

# ---------------------------------------------------------------------------
# 1. 配置你的定制文件 GitHub 仓库地址
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/dayunliang/OpenWRT_Customized.git"

# 2. 创建临时目录用于 clone 仓库，TS 为当前时间戳用于备份文件名
TMP_DIR=$(mktemp -d)
TS=$(date +%Y%m%d-%H%M%S)

echo "1. 克隆自定义文件仓库到临时目录 $TMP_DIR ..."
git clone --depth=1 "$REPO_URL" "$TMP_DIR"

# ---------------------------------------------------------------------------
# 3. 封装一个带自动备份的复制函数 safe_cp
# ---------------------------------------------------------------------------
# 用法：safe_cp 源文件 目标文件
#  - 如果目标文件已存在，则自动备份为 .bak.时间戳 文件
#  - 然后执行覆盖复制
safe_cp() {
    src="$1"
    dst="$2"
    # 检查目标文件是否存在且是普通文件
    if [ -f "$dst" ]; then
        echo "  [备份] 检测到已有同名文件 $dst，备份为 $dst.bak.$TS"
        cp -v "$dst" "$dst.bak.$TS"
    fi
    # 覆盖复制源文件到目标
    cp -vf "$src" "$dst"
}

# ---------------------------------------------------------------------------
# 4. 依次分发自定义文件，自动检测目录并创建
#    每一步都详细注释文件含义和目标路径
# ---------------------------------------------------------------------------

echo "2. 分发自定义文件到指定目录（如有同名旧文件则自动备份）..."

# 4.1 feeds.conf.default (OpenWrt 源码根目录的 feed 源配置文件)
safe_cp "$TMP_DIR/Lean/feeds.conf.default" "./feeds.conf.default"

# 4.2 zzz-default-settings (Lean 默认设置脚本，编译时自动应用)
mkdir -p ./package/lean/default-settings/files
safe_cp "$TMP_DIR/Lean/zzz-default-settings" "./package/lean/default-settings/files/zzz-default-settings"

# 4.3 back-route 相关自定义脚本 (放到固件的 /usr/bin/ 目录)
mkdir -p ./files/usr/bin
safe_cp "$TMP_DIR/Lean/back-route-checkenv.sh" "./files/usr/bin/back-route-checkenv.sh"
safe_cp "$TMP_DIR/Lean/back-route-complete.sh" "./files/usr/bin/back-route-complete.sh"
safe_cp "$TMP_DIR/Lean/back-route-cron.sh" "./files/usr/bin/back-route-cron.sh"
chmod +x ./files/usr/bin/back-route-*.sh  # 保证脚本有执行权限

# 4.4 IPsec 配置文件 (固件内 /etc/ 目录)
mkdir -p ./files/etc
safe_cp "$TMP_DIR/Lean/ipsec.conf" "./files/etc/ipsec.conf"
safe_cp "$TMP_DIR/Lean/ipsec.secrets" "./files/etc/ipsec.secrets"

# 4.5 luci-app-ipsec-server 配置文件（如有，放到 /etc/config/ 目录）
if [ -f "$TMP_DIR/Lean/luci-app-ipsec-server" ]; then
    mkdir -p ./files/etc/config
    safe_cp "$TMP_DIR/Lean/luci-app-ipsec-server" "./files/etc/config/luci-app-ipsec-server"
fi

# 4.6 crontab 定时任务 root 文件（固件内 /etc/crontabs/root，管理所有 root 用户定时任务）
mkdir -p ./files/etc/crontabs
safe_cp "$TMP_DIR/Lean/root" "./files/etc/crontabs/root"

# ---------------------------------------------------------------------------
# 5. 清理临时目录，保证编译环境整洁
# ---------------------------------------------------------------------------
echo "3. 清理临时目录 $TMP_DIR"
rm -rf "$TMP_DIR"

# ---------------------------------------------------------------------------
# 6. 脚本完成提示
# ---------------------------------------------------------------------------
echo "所有自定义文件已安全分发并自动备份到对应目录，部署完毕。"
echo "如需还原任意被覆盖文件，请手动用 *.bak.时间戳 文件还原即可。"

# ---------------------- END OF SCRIPT --------------------------------------
