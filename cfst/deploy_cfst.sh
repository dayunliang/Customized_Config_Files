#!/bin/sh

# 1. 进入绝对路径工作目录
cd /root/cfst

# 2. 建立本地持久化目录
mkdir -p ./data
mkdir -p ./config

# 3. 强制下载覆盖最新的 compose 配置文件
wget -O docker-compose.yml https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/CFST/cfst/docker-compose.yml

# 4. 拉取线上最新镜像并彻底清理可能残留的孤儿容器
docker compose pull
docker compose down --remove-orphans

# 5. 启动容器进行测速（阻塞等待直至结束）
docker compose up

# 6. 将 csv 的第1列和第7列抓取出来，缝合成 IP:443#地区 格式并写入新文件
awk -F',' 'NR>1 {gsub(/\r/,"",$7); print $1":443#"$7}' data/result.csv > data/result.txt

# =====================================================================
# 🚀 自动化 Git-API 推送流水线（利用 for 循环同时处理双文件）
# =====================================================================

# 7. 基础公共变量配置（注：此处的 Token 记得换成你网页端新生成的密钥）
GH_TOKEN="填写GH秘钥"
GH_REPO="dayunliang/Customized_Config_Files"

# 8. 开启循环，依次处理两个文件
for FILE_NAME in "result.csv" "result.txt"; do

    # 9. 动态组合当前文件的云端相对路径和本地绝对路径
    REMOTE_PATH="CFST/cfst/data/$FILE_NAME"
    LOCAL_FILE="/root/cfst/data/$FILE_NAME"

    # 10. 探测云端该位置是否已有当前文件，并抓取其 SHA 身份证
    CURRENT_SHA=$(curl -s -H "Authorization: token $GH_TOKEN" "https://api.github.com/repos/$GH_REPO/contents/$REMOTE_PATH" | jq -r '.sha')

    # 11. 将本地当前文件内容打包为 Base64 编码并剔除换行
    BASE64_TEXT=$(base64 $LOCAL_FILE | tr -d '\n')

    # 12. 动态判定：如果是首次上传则不带 sha，如果是日常更新则必须携带 sha 身份证
    if [ "$CURRENT_SHA" = "null" ] || [ -z "$CURRENT_SHA" ]; then JSON_DATA="{\"message\":\"Cron: auto init $FILE_NAME\",\"content\":\"$BASE64_TEXT\"}"; else JSON_DATA="{\"message\":\"Cron: auto update $FILE_NAME\",\"content\":\"$BASE64_TEXT\",\"sha\":\"$CURRENT_SHA\"}"; fi

    # 13. 通过 API 将当前文件精准发射到 GitHub 对应的路径下
    curl -s -X PUT -H "Authorization: token $GH_TOKEN" -H "Content-Type: application/json" -d "$JSON_DATA" "https://api.github.com/repos/$GH_REPO/contents/$REMOTE_PATH" > /dev/null

done
