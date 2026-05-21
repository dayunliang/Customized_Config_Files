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
    git clone --filter=blob:none --sparse git@github.com:dayunliang/Customized_Config_Files.git "$REPO_DIR"
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
