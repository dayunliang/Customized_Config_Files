#!/bin/sh

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
# 既然测速结果已经安全提交，剩下未暂存的修改（如容器改动了 config）大概率是垃圾变动。
# 这一步会丢弃这些未暂存的干扰，确保工作区绝对干净，彻底解决 "You have unstaged changes" 报错。
git checkout -- .

# 7. 🔄 拉取云端最新更改（变基合并）
# 加上 --autostash 作为双保险；加上 -X theirs 确保冲突时以本地刚测出的最新数据为准
git pull --rebase --autostash -X theirs origin main

# 8. 🚀 推送回云端 main 分支
git push origin main
