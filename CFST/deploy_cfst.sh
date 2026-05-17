#!/bin/sh

# 1. 统一进入家目录下的工作文件夹，如果不存在则创建
mkdir -p ~/cfst
cd ~/cfst

# 2. 创建持久化数据和配置目录
mkdir -p ./data
mkdir -p ./config

# 3. 下载最新的配置文件
# 核心修复：增加 -O 参数，确保每次都强制覆盖并更新为最新的 docker-compose.yml
wget -O docker-compose.yml https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/CFST/cfst/docker-compose.yml

# 4. 拉取线上最新的 cfst 镜像
docker compose pull

# 5. 启动容器开始跑测速
docker compose up -d
