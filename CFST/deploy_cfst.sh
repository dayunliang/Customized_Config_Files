#!/bin/sh
mkdir -p /root/cfst
cd ~/cfst
mkdir -p ./data
mkdir -p ./config
wget xxx
docker compose pull
docker compose up -d
