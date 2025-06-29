#!/bin/bash
# ===========================================================================
# Lean OpenWrt 定制文件一键部署脚本（自动备份 + 缺失即停 + 下载校验）
# 作者：https://github.com/dayunliang
# ===========================================================================

set -e  # 只要脚本中任意一条命令失败，立即退出，防止脏环境构建

# ===========================================================================
# 1. 基本变量定义
# ===========================================================================
REPO_URL="https://github.com/dayunliang/Customized_Config_Files.git"  # GitHub 仓库地址
TMP_DIR=$(mktemp -d)    # 创建临时目录用于 clone 仓库
TS=$(date +%Y%m%d-%H%M%S)  # 当前时间戳用于文件备份命名
declare -a BACKUP_LIST     # 定义备份清单数组，记录所有被自动备份的文件

# ===========================================================================
# 2. 克隆 Git 仓库
# ===========================================================================
echo "1. 克隆自定义文件仓库到临时目录 $TMP_DIR ..."
if ! git clone --depth=1 "$REPO_URL" "$TMP_DIR"; then
    echo "❌ 克隆仓库失败，请检查网络或仓库地址是否正确：$REPO_URL"
    exit 1
fi

# ===========================================================================
# 3. 复制函数（带备份机制）
# ===========================================================================
safe_cp() {
    src="$1"
    dst="$2"
    if [ -f "$dst" ]; then
        backup_name="$dst.bak.$TS"
        cp -v "$dst" "$backup_name"
        BACKUP_LIST+=("$backup_name")  # 添加到备份列表
    fi
    cp -vf "$src" "$dst"  # 强制复制并显示过程
}

# ===========================================================================
# 4. 部署函数（复制前校验 + 自动创建目录）
# ===========================================================================
deploy_file() {
    desc="$1"  # 文件描述（用于错误提示）
    src="$2"
    dst="$3"

    if [ ! -f "$src" ]; then
        echo "❌ 错误：缺失文件 [$desc]：$src"
        exit 1
    fi

    mkdir -p "$(dirname "$dst")"  # 自动创建目标目录
    safe_cp "$src" "$dst"
}

# ===========================================================================
# 5. 部署配置文件
# ===========================================================================
echo "2. 分发自定义文件到指定目录..."

deploy_file ".config Buildroot核心配置文件" "$TMP_DIR/Lean/config" "./.config"
echo "📦 Lean/config 已部署为 .config（OpenWrt 编译配置文件）"

deploy_file "feeds.conf.default 源列表配置文件" "$TMP_DIR/Lean/feeds.conf.default" "./feeds.conf.default"
deploy_file "zzz-default-settings 系统初始化设置脚本" "$TMP_DIR/Lean/zzz-default-settings" "./package/lean/default-settings/files/zzz-default-settings"

deploy_file "back-route-checkenv.sh 路由检查脚本" "$TMP_DIR/Lean/files/usr/bin/back-route-checkenv.sh" "./files/usr/bin/back-route-checkenv.sh"
deploy_file "back-route-complete.sh 回程路由脚本" "$TMP_DIR/Lean/files/usr/bin/back-route-complete.sh" "./files/usr/bin/back-route-complete.sh"
deploy_file "back-route-cron.sh 回程路由定时检查脚本" "$TMP_DIR/Lean/files/usr/bin/back-route-cron.sh" "./files/usr/bin/back-route-cron.sh"

chmod +x ./files/usr/bin/back-route-*.sh 2>/dev/null || true  # 为 back-route 脚本添加执行权限

deploy_file "ipsec.conf IPsec-VPN核心配置文件" "$TMP_DIR/Lean/files/etc/ipsec.conf" "./files/etc/ipsec.conf"
deploy_file "ipsec.secrets IPSec-VPN密钥配置文件" "$TMP_DIR/Lean/files/etc/ipsec.secrets" "./files/etc/ipsec.secrets"
deploy_file "luci-app-ipsec-server IPSec-WEB插件配置文件" "$TMP_DIR/Lean/files/etc/config/luci-app-ipsec-server" "./files/etc/config/luci-app-ipsec-server"
deploy_file "avahi-daemon.conf Avahi-Daemon配置文件" "$TMP_DIR/Lean/files/etc/avahi/avahi-daemon.conf" "./files/etc/avahi/avahi-daemon.conf"
deploy_file "root crontab 定时任务" "$TMP_DIR/Lean/files/etc/crontabs/root" "./files/etc/crontabs/root"

# ===========================================================================
# 6. 清理临时 clone 仓库
# ===========================================================================
echo "3. 清理临时目录 $TMP_DIR"
rm -rf "$TMP_DIR"

# ===========================================================================
# 7. 构建准备：feeds update/install + make defconfig
# ===========================================================================
echo
echo "🛠️ 开始构建前准备步骤（make defconfig / feeds update / feeds install）..."

# 更新 feeds 源中所有包描述（sources）
echo "🌐 执行 ./scripts/feeds update -a ..."
./scripts/feeds update -a

# 安装 feeds 到 package/feeds 目录，准备编译
echo "📦 执行 ./scripts/feeds install -a ..."
./scripts/feeds install -a

# make defconfig 可清理无效配置项，并补全所需默认值
echo "🔧 执行 make defconfig..."
make defconfig

# ===========================================================================
# 8. 是否首次执行构建（决定是否自动 download）
# ===========================================================================
echo
read -p "🧐 是否是首次执行此编译环境？需要预下载所有源码包？(y/N): " is_first

if [[ "$is_first" == "y" || "$is_first" == "Y" ]]; then
    echo
    echo "📥 正在预下载所有编译所需源码包（make download -j8 V=s）..."
    while true; do
        make download -j8 V=s
        echo "🔍 检查是否有下载不完整的小文件（<1KB）..."
        broken=$(find dl -size -1024c)

        if [ -z "$broken" ]; then
            echo "✅ 所有软件包已完整下载。"
            break
        else
            echo "⚠️ 检测到以下不完整文件，将删除后重新下载："
            echo "$broken"
            find dl -size -1024c -exec rm -f {} \;
            echo "🔁 重新执行下载..."
        fi
    done
else
    echo
    echo "✅ 跳过预下载，假设你已执行过 make download。"
    echo "👉 你现在可以继续执行编译命令："
    echo
    echo "   make -j$(nproc) V=s"
    echo
fi

# ===========================================================================
# 9. 展示所有自动备份的文件（部署完成后最后统一展示）
# ===========================================================================
if [ ${#BACKUP_LIST[@]} -gt 0 ]; then
    echo
    echo "======================================================="
    echo "🗂️ 本次操作已自动备份的原有文件清单如下："
    for f in "${BACKUP_LIST[@]}"; do
        echo "  $f"
    done
    echo "如需还原原文件，请将上述 .bak.时间戳 文件复制覆盖回原名即可。"
    echo "======================================================="
else
    echo
    echo "🗂️ 本次未检测到需要备份的已有同名文件，无备份操作。"
fi

# ===========================================================================
# 10. 最终提示
# ===========================================================================
echo
echo "🚀 所有配置部署和构建准备已完成。"
echo "📂 当前目录为：$(pwd)"
echo "📝 可开始编译：make -j$(nproc) V=s"
