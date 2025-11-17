#!/bin/bash
# 删除/屏蔽掉编译中用不到、会引发循环依赖或冲突的包
# 并对 .config 做兜底清理（强制关闭部分包）

set -e

echo "=== [remove_conflict.sh] 清理无用 / 有冲突的包 ==="

# 1. Passwall / Bypass / Fchomo
rm -rf feeds/small/luci-app-bypass
rm -rf feeds/small/luci-app-passwall
rm -rf feeds/small/luci-app-passwall2
rm -rf feeds/small/luci-app-fchomo

# 2. Baresip + Apps
rm -rf feeds/telephony/net/baresip
rm -rf package/feeds/telephony/baresip-apps
rm -rf feeds/telephony/baresip-apps

# 3. 零梯加速
rm -rf package/feeds/istore/luci-app-LingTiGameAcc

# 4. luci-app-ssr-plus（及其 i18n）
rm -rf feeds/small/luci-app-ssr-plus

# 5. 对 .config 做兜底：强制关闭 ssr-plus
if [ -f .config ]; then
    echo "=== [remove_conflict.sh] 修正 .config 中的 ssr-plus 相关配置 ==="

    # 删掉所有关于 ssr-plus 的行
    sed -i '/CONFIG_PACKAGE_luci-app-ssr-plus/d' .config
    sed -i '/CONFIG_PACKAGE_luci-i18n-ssr-plus-zh-cn/d' .config
    sed -i '/CONFIG_DEFAULT_luci-app-ssr-plus/d' .config

    # 追加标准 not set 写法
    cat >> .config <<'EOF'
# CONFIG_PACKAGE_luci-app-ssr-plus is not set
# CONFIG_PACKAGE_luci-i18n-ssr-plus-zh-cn is not set
# CONFIG_DEFAULT_luci-app-ssr-plus is not set
EOF

    echo "✅ 已将 ssr-plus 及中文包强制设为 not set"
fi

echo "✅ [remove_conflict.sh] 处理完成"
exit 0
