#!/bin/bash
# 删除/屏蔽掉编译中用不到、会引发循环依赖的包

# Passwall / Bypass / Fchomo
rm -rf feeds/small/luci-app-bypass
rm -rf feeds/small/luci-app-passwall
rm -rf feeds/small/luci-app-passwall2
rm -rf feeds/small/luci-app-fchomo

# Baresip + Apps
rm -rf feeds/telephony/net/baresip
rm -rf package/feeds/telephony/baresip-apps

# LingTiGameAcc
rm -rf package/feeds/istore/luci-app-LingTiGameAcc

# 确保 ssr-plus 不再依赖 dns2socks-rust
# 自动注释掉那一行
sed -i 's/^\s*+PACKAGE_$(PKG_NAME)_INCLUDE_DNS2SOCKS_RUST.*/#& \\/' feeds/small/luci-app-ssr-plus/Makefile
