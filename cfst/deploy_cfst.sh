#!/bin/sh

# =====================================================================
# ⚙️ 基础路径与环境配置（统一在这里修改，后面一劳永逸）
# =====================================================================
BASE_DIR="/root"
REPO_DIR="$BASE_DIR/.config_repo"
WORK_DIR="$BASE_DIR/cfst"

# 1. 确保进入大本营
cd "$BASE_DIR" || exit 1

# 2. 🚀 隐形初始化：如果隐藏仓库壳子不存在，则克隆到隐藏目录中
if [ ! -d "$REPO_DIR" ]; then
    git clone --filter=blob:none --sparse git@github.com:dayunliang/Customized_Config_Files.git "$REPO_DIR"
    cd "$REPO_DIR" || exit 1
    git sparse-checkout set cfst
    # 🌟 自动建立映射软链接（-sf 确保即便残留快捷方式也能强行覆盖绑定）
    ln -sf "$REPO_DIR/cfst" "$WORK_DIR"
fi

# 3. 🎯 完美切入你的目标工作目录
cd "$WORK_DIR" || exit 1

# 4. 同步云端最新的代码和配置（已全面对齐 main 主分支）
git pull origin main

# 5. 拉取最新的测速镜像并清理旧容器
docker compose pull
docker compose down --remove-orphans

# 6. 启动容器进行测速（阻塞死守着容器跑完并自动退出）
docker compose up

# 7. 提取 IP:443#地区 格式并写入 txt
awk -F',' 'NR>1 {gsub(/\r/,"",$7); print $1":443#"$7}' data/result.csv > data/result.txt

# 8. Git 本地账户对齐（防止 cron 环境下因为没有全局 user 导致报错罢工）
git config user.name "alpine-cron"
git config user.email "cron@homelab.local"

# 9. 循环添加文件到暂存区
for FILE_NAME in "result.csv" "result.txt"; do
    git add "data/$FILE_NAME"
done

# 10. 统一提交并盖上当前精确的时间戳大印
git commit -m "Cron: auto update speedtest results [$(date '+%Y-%m-%d %H:%M:%S')]"

# 11. 🚀 最后一脚油门，凭本地隐形 SSH KEY 顺着软链接直接盲推回云端 main 分支！
git push origin main
