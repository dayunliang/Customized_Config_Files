#!/bin/sh

# =====================================================================
# ⚙️ 基础路径与环境配置
# =====================================================================
BASE_DIR="/root"
REPO_DIR="$BASE_DIR/.config_repo"
WORK_DIR="$BASE_DIR/cfst"

# 1. 确保进入大本营
cd "$BASE_DIR" || exit 1

# 2. 🚀 隐形初始化：如果隐藏仓库壳子不存在，则克隆它
if [ ! -d "$REPO_DIR" ]; then
    # 优化：改用 HTTPS 协议，并只克隆最后一层历史(depth 1)，极大减少下载量
    git clone --depth 1 --sparse https://github.com/dayunliang/Customized_Config_Files.git "$REPO_DIR"
    cd "$REPO_DIR" || exit 1
    git sparse-checkout set cfst
fi

# 3. 🌟 核心修正：强制重置软链接大门（直接在 /root 下建立映射，绝不套娃）
rm -f "$WORK_DIR"
ln -s "$REPO_DIR/cfst" "$WORK_DIR"

# 4. 🎯 精准切入你的工作目录
cd "$WORK_DIR" || exit 1

# 5. 同步云端最新的代码和配置
git pull origin main

# 6. 拉取最新的测速镜像并清理旧容器
docker compose pull
docker compose down --remove-orphans

# 7. 启动容器进行测速
docker compose up

# 8. 提取 IP:443#地区 格式并写入 txt
awk -F',' 'NR>1 {gsub(/\r/,"",$7); print $1":443#"$7}' data/result.csv > data/result.txt

# =====================================================================
# 💾 Git 自动化提交与同步 (终极防卡死版)
# =====================================================================

# 9. Git 本地账户对齐
git config user.name "alpine-cron"
git config user.email "cron@homelab.local"

# 10. 循环添加文件到暂存区
for FILE_NAME in "result.csv" "result.txt"; do
    git add "data/$FILE_NAME"
done

# 11. 统一提交
git commit -m "Cron: auto update speedtest results [$(date '+%Y-%m-%d %H:%M:%S')]" || echo "No changes to commit"

# 12. 🧹 核心修复：强制清理工作区残留的“脏变动”
# 既然测速结果已经安全提交，剩下未暂存的修改（如容器改动了 config）大概率是垃圾变动。
# 这一步会丢弃这些未暂存的干扰，确保工作区绝对干净，彻底解决 "You have unstaged changes" 报错。
git checkout -- .

# 13. 🔄 拉取云端最新更改（变基合并）
# 加上 --autostash 作为双保险；加上 -X theirs 确保冲突时以本地刚测出的最新数据为准
git pull --rebase --autostash -X theirs origin main

# 14. 🚀 推送回云端 main 分支
git push origin main
