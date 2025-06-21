# 一键部署自用 MosDNS + AdGuardHome（分流：CN + GFW）

> 🧩 本项目旨在通过简单脚本，一键部署 `MosDNS` + `AdGuardHome` 双实例，实现高效的 DNS 分流：**国内请求走国内解析（CN）**，**国外/GFW 域名走代理（GFW）**，有效防止 DNS 泄露，提升网络体验。

---

## ✨ 功能特性

- 📦 一键安装 MosDNS 和两套 AdGuardHome（CN / GFW）容器
- ⚙️ 自动配置国内外 DNS 分流规则（支持 GeoIP / geosite）
- 🔧 自动释放占用端口（53/54/55），避免冲突
- 🧱 支持定时更新配置与规则文件（可选）
- 📜 可选通过 GitHub 代理下载配置文件，适配国内环境

- 🌐 DNS 分流逻辑
🇨🇳 国内域名（CN）：

MosDNS 检测到 geosite:cn / geoip:cn，转发给 AdH_CN（监听端口：54）

🌍 国外域名 / GFW 域名：

转发给 AdH_GFW（监听端口：55），其上游为代理节点或海外 DNS（如 8.8.8.8）

---

## 📂 项目结构

```bash
.
├── deploy_mosdns_AdH.sh        # 主部署脚本（一键执行）
├── conf/
│   ├── AdH_CN.yaml             # 国内 ADH 配置文件
│   ├── AdH_GFW.yaml            # 国外 ADH 配置文件
│   ├── config_custom.yaml      # MosDNS 主配置
│   └── dat_exec.yaml           # MosDNS 数据规则配置
└── docker-compose/
    ├── docker-compose.AdH_CN.yaml
    ├── docker-compose.AdH_GFW.yaml
    └── docker-compose.mosdns.yaml

🚀 快速开始

1️⃣ 准备环境
推荐平台：Alpine (建议) / Debian / Ubuntu

2️⃣ 一键部署
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/deploy_mosdns_AdH.sh | bash

或使用 Github Proxy

curl -fsSL https://goppx.com/https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/deploy_mosdns_AdH.sh | bash

📜 LICENSE
本项目使用 MIT License 开源。

👤 作者
Andy Da
📬 欢迎交流建议或提 Issue

🧭 鸣谢
MosDNS

AdGuardHome

geosite 数据
