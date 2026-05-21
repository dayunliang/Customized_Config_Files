#!/bin/sh

# =====================================================================
# 🎯 关键：进入工作目录（否则 cron 执行时会找不到 docker-compose.yml 和 git 仓库）
# =====================================================================
cd /root/cfst || exit 1

# 1. 启动容器进行测速
docker compose up

# 2. 提取 IP:443#地区 格式并写入 txt
awk -F',' 'NR>1 {gsub(/\r/,"",$7); print $1":443#"$7}' data/result.csv > data/result.txt

# =====================================================================
# 💾 Git 自动化提交与同步 (终极防卡死版)
# =====================================================================

# 3. Git 本地账户对齐
git config user.name "alpine-cron"
git config user.email "cron@homelab.local"

# 4. 循环添加文件到暂存区
for FILE_NAME in "result.csv" "result.txt"; do
    git add "data/$FILE_NAME"
done

# 5. 统一提交
git commit -m "Cron: auto update speedtest results [$(date '+%Y-%m-%d %H:%M:%S')]" || echo "No changes to commit"

# 6. 🧹 核心修复：强制清理工作区残留的“脏变动”
git checkout -- .

# 7. 🔄 拉取云端最新更改（变基合并）
git pull --rebase --autostash -X theirs origin main

# 8. 🚀 推送回云端 main 分支
git push origin main
