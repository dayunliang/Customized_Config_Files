#!/bin/bash
# ===========================================================================
# Lean OpenWrt 定制文件一键部署脚本（自动备份 + 缺失即停 + 展示备份清单）
# 作者：你自己（https://github.com/dayunliang）
# ===========================================================================

# 只要有一条命令出错，立即终止整个脚本，防止部署脏文件
set -e

# ===========================================================================
# 1. 变量定义区
# ===========================================================================

# Git 仓库地址（包含 Lean 目录下的自定义配置文件）
REPO_URL="https://github.com/dayunliang/Customized_Config_Files.git"

# 创建一个临时目录，用于 clone 仓库，不污染当前工作目录
TMP_DIR=$(mktemp -d)

# 生成当前时间戳，用于备份文件名（格式：20250629-123456）
TS=$(date +%Y%m%d-%H%M%S)

# 声明一个数组，用于记录所有被自动备份的原文件路径
declare -a BACKUP_LIST

# ===========================================================================
# 2. 克隆自定义文件仓库
# ===========================================================================
echo "1. 克隆自定义文件仓库到临时目录 $TMP_DIR ..."
if ! git clone --depth=1 "$REPO_URL" "$TMP_DIR"; then
    echo "❌ 克隆仓库失败，请检查网络或仓库地址是否正确：$REPO_URL"
    exit 1
fi

# ===========================================================================
# 3. 复制函数：包含自动备份逻辑（不做文件存在判断）
# ===========================================================================
safe_cp() {
    src="$1"  # 源文件路径
    dst="$2"  # 目标文件路径

    # 如果目标文件已存在，先自动备份
    if [ -f "$dst" ]; then
        backup_name="$dst.bak.$TS"
        cp -v "$dst" "$backup_name"
        BACKUP_LIST+=("$backup_name")  # 把备份文件名加入清单
    fi

    # 复制新文件到目标位置
    cp -vf "$src" "$dst"
}

# ===========================================================================
# 4. 包装函数：先检查文件是否存在，缺失即停；然后自动创建目录并复制
# ===========================================================================
deploy_file() {
    desc="$1"  # 描述（如 “IPsec 配置文件”）
    src="$2"   # 源路径
    dst="$3"   # 目标路径

    if [ ! -f "$src" ]; then
        echo "❌ 错误：缺失文件 [$desc]：$src"
        exit 1
    fi

    # 创建目标目录（若不存在）
    mkdir -p "$(dirname "$dst")"

    # 执行复制逻辑
    safe_cp "$src" "$dst"
}

# ===========================================================================
# 5. 分发定制文件到 Lean OpenWrt 源码目录
# ===========================================================================
echo "2. 分发自定义文件到指定目录..."

# 5.1 .config（OpenWrt 编译系统核心配置文件）
deploy_file ".config Buildroot 核心配置文件" "$TMP_DIR/Lean/config" "./.config"
echo "📦 Lean/config 已部署为 .config（OpenWrt 编译配置文件）"

# 立即处理 .config，使其适配当前 OpenWrt 版本及可用组件
echo "🔧 正在执行 make defconfig..."
make defconfig

# 更新 & 安装 feeds
echo "🌐 执行 scripts/feeds update -a ..."
./scripts/feeds update -a

echo "📦 执行 scripts/feeds install -a ..."
./scripts/feeds install -a


# 5.2 feeds.conf.default（OpenWrt 软件源配置）
deploy_file "feeds.conf.default OpenWRT 源列表配置文件" "$TMP_DIR/Lean/feeds.conf.default" "./feeds.conf.default"

# 5.3 zzz-default-settings（默认配置脚本）
deploy_file "zzz-default-settings OpenWRT 系统初始化设置脚本" "$TMP_DIR/Lean/zzz-default-settings" "./package/lean/default-settings/files/zzz-default-settings"

# 5.4 back-route 系列脚本（3 个）
deploy_file "back-route-checkenv.sh 路由检查脚本" "$TMP_DIR/Lean/files/usr/bin/back-route-checkenv.sh" "./files/usr/bin/back-route-checkenv.sh"
deploy_file "back-route-complete.sh 回程路由脚本" "$TMP_DIR/Lean/files/usr/bin/back-route-complete.sh" "./files/usr/bin/back-route-complete.sh"
deploy_file "back-route-cron.sh 回程路由定时检查脚本" "$TMP_DIR/Lean/files/usr/bin/back-route-cron.sh" "./files/usr/bin/back-route-cron.sh"

# back-route 系列脚本统一添加可执行权限（即使重复执行也无影响）
chmod +x ./files/usr/bin/back-route-*.sh 2>/dev/null || true

# 5.5 IPsec 配置文件（2 个）
deploy_file "ipsec.conf IPsec-VPN核心配置文件" "$TMP_DIR/Lean/files/etc/ipsec.conf" "./files/etc/ipsec.conf"
deploy_file "ipsec.secrets IPSec-VPN密钥配置文件" "$TMP_DIR/Lean/files/etc/ipsec.secrets" "./files/etc/ipsec.secrets"

# 5.6 luci-app-ipsec-server 配置（如果启用了此插件）
deploy_file "luci-app-ipsec-server IPSec-WEB插件配置文件" "$TMP_DIR/Lean/files/etc/config/luci-app-ipsec-server" "./files/etc/config/luci-app-ipsec-server"

# 5.7 avahi-daemon 配置（用于 mDNS 服务）
deploy_file "avahi-daemon.conf Avahi-Daemon配置文件" "$TMP_DIR/Lean/files/etc/avahi/avahi-daemon.conf" "./files/etc/avahi/avahi-daemon.conf"

# 5.8 crontab 定时任务文件（OpenWrt root 用户）
deploy_file "root crontab 定时任务" "$TMP_DIR/Lean/files/etc/crontabs/root" "./files/etc/crontabs/root"

# ===========================================================================
# 6. 清理临时目录
# ===========================================================================
echo "3. 清理临时目录 $TMP_DIR"
rm -rf "$TMP_DIR"

# ===========================================================================
# 7. 展示所有备份的原始文件清单（如有）
# ===========================================================================
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

# ===========================================================================
# 8. 脚本结束提示
# ===========================================================================
echo
echo "✅ 所有自定义文件已成功部署，脚本执行完毕。"
