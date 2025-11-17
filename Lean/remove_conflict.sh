#!/bin/bash
# 删除/屏蔽掉编译中用不到、会引发循环依赖或冲突的包

set -e

echo "=== [remove_conflict.sh] 清理无用 / 有冲突的包 ==="

# ----------------------------
# 1. Passwall / Bypass / Fchomo
# ----------------------------
rm -rf feeds/small/luci-app-bypass
rm -rf feeds/small/luci-app-passwall
rm -rf feeds/small/luci-app-passwall2
rm -rf feeds/small/luci-app-fchomo

# ----------------------------
# 2. Baresip + Apps
# ----------------------------
rm -rf feeds/telephony/net/baresip
rm -rf package/feeds/telephony/baresip-apps
rm -rf feeds/telephony/baresip-apps

# ----------------------------
# 3. 零梯加速
# ----------------------------
rm -rf package/feeds/istore/luci-app-LingTiGameAcc

# ----------------------------
# 4. luci-app-ssr-plus（及其 i18n）
#    → 目前不需要，彻底从 small feed 中移除
# ----------------------------
rm -rf feeds/small/luci-app-ssr-plus

echo "✅ [remove_conflict.sh] 清理完成"
exit 0
