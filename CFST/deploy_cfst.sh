#!/bin/sh

# 1. 进入家目录下的工作文件夹
mkdir -p ~/cfst
cd ~/cfst

# 2. 创建持久化数据和配置目录
mkdir -p ./data
mkdir -p ./config

# 3. 强制下载覆盖最新的配置文件
wget -O docker-compose.yml https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/CFST/cfst/docker-compose.yml

# 4. 拉取线上最新的镜像
docker compose pull

# 5. 核心安全保障：瞬间停止并清理旧项目下的所有容器
# --remove-orphans 会顺手把改名了的、废弃的旧容器连根拔起，瞬间释放 IP
docker compose down --remove-orphans

# 6. 干干净净地启动全新配置的容器
docker compose up -d
