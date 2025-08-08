#!/bin/bash
# 调用核心更新脚本
/usr/share/openclash/openclash-core.sh "$@"
# 然后不管成功还是失败，都关一次 DNS
if [ -x "/etc/openclash/dns_enable_false.sh" ]; then
  sh /etc/openclash/dns_enable_false.sh
fi
