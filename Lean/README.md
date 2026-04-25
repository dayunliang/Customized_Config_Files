# 🚀 Lean OpenWrt 一键部署脚本

本项目是基于 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) 的 OpenWrt 编译系统的**一键部署助手**，自动分发用户自定义配置文件，并完成编译前的准备流程。

> 🧠 自动备份、缺失即停、首次执行智能下载校验，一步到位。

---

## ✨ 功能特性

- ✅ 自动克隆用户自定义配置仓库
- ✅ 将所有定制脚本和配置文件复制到 OpenWrt 源码目录中
- ✅ 复制前自动备份原有文件（`.bak.时间戳`）
- ✅ 关键文件缺失即停止并提示位置
- ✅ 自动执行 `feeds update -a` / `feeds install -a` / `make defconfig`
- ✅ 首次构建时自动执行 `make download`，并检测 `dl/` 是否存在损坏文件
- ✅ 所有步骤中文注释和输出提示清晰友好

## 🗂️ 自定义文件仓库结构要求

你应将所有定制文件放在 Git 仓库的 `Lean/` 目录下，结构示例：

```
Customized_Config_Files/
└── Lean/
    ├── config                        # 主构建配置，将被复制为 .config
    ├── feeds.conf.default            # 软件源定义
    ├── zzz-default-settings          # 默认设置脚本
    └── files/
        ├── usr/bin/
        │   ├── back-route-checkenv.sh
        │   ├── back-route-complete.sh
        │   └── back-route-cron.sh
        ├── etc/
        │   ├── ipsec.conf
        │   ├── ipsec.secrets
        │   ├── config/
        │   │   └── luci-app-ipsec-server
        │   ├── avahi/
        │   │   └── avahi-daemon.conf
        │   └── crontabs/
        │       └── root
```

## ⚙️ 使用方法

1. 确保你已经克隆 Lean OpenWrt 到本地，例如：

   ```bash
   git clone https://github.com/coolsnowwolf/lede openwrt
   cd openwrt
   wget https://raw.githubusercontent.com/你的用户名/你的仓库名/main/deploy_openwrt.sh
   chmod +x deploy_openwrt.sh
   ./deploy_openwrt.sh

   根据提示选择是否首次构建环境：

✅ 若为首次，将自动 download 并校验

✅ 否则可直接进入编译流程

    make -j$(nproc) V=s

💾 自动备份说明

脚本会在每次覆盖原始文件前备份为：xxx.bak.20250629-103045
