#!/bin/sh
mkdir -p /root/cfst
cd ~/cfst
mkdir -p ./data
mkdir -p ./config
wget https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/CFST/cfst/docker-compose.yml
docker compose pull
docker compose up -d
