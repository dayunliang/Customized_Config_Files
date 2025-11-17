#!/bin/bash
# 删除/屏蔽掉编译中用不到、会引发循环依赖的包

set -e

# Passwall / Bypass / Fchomo
rm -rf feeds/small/luci-app-bypass
rm -rf feeds/small/luci-app-passwall
rm -rf feeds/small/luci-app-passwall2
rm -rf feeds/small/luci-app-fchomo

# Baresip + Apps
rm -rf feeds/telephony/net/baresip
rm -rf package/feeds/telephony/baresip-apps
rm -rf feeds/telephony/baresip-apps

# LingTiGameAcc
rm -rf package/feeds/istore/luci-app-LingTiGameAcc

# 确保 ssr-plus 不再依赖 dns2socks-rust
# 自动注释掉那一行
SSR_MK="feeds/small/luci-app-ssr-plus/Makefile"

if [ -f "$SSR_MK" ]; then
    # 注意这里要匹配字面量 $(PKG_NAME)，所以用 \$
    if grep -q 'PACKAGE_\$(PKG_NAME)_INCLUDE_DNS2SOCKS_RUST' "$SSR_MK"; then
        # 同理，sed 里也用字面量 $(PKG_NAME)
        sed -i 's/^[[:space:]]*+PACKAGE_\$(PKG_NAME)_INCLUDE_DNS2SOCKS_RUST/# &/' "$SSR_MK"
        echo "✅ 已注释 dns2socks-rust 依赖"
    else
        echo "ℹ️ luci-app-ssr-plus 不包含 dns2socks-rust 依赖，跳过修改"
    fi
else
    echo "⚠️ 未找到 luci-app-ssr-plus/Makefile，跳过修改"
fi
