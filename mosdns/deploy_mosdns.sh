#!/bin/sh
set -e

# 1. 检查 docker-compose 是否已安装
if ! command -v docker-compose >/dev/null 2>&1; then
  echo "[1/8] 未检测到 docker-compose，正在安装..."
  apk update
  apk add --no-cache docker-compose
else
  echo "[1/8] 检测到 docker-compose，跳过安装。"
fi

# 2. 停止并删除同名容器，重建工作目录
echo "[2/8] 清理旧容器与目录…"
if docker ps -a --format '{{.Names}}' | grep -xq mosdns; then
  docker rm -f mosdns
  echo "  已删除旧容器 mosdns"
fi
rm -rf ~/mosdns
mkdir -p ~/mosdns
echo "  已重建目录 ~/mosdns"

# 3. 检查 53 端口占用
echo "[3/8] 检查端口 53 占用…"
occupiers=$(lsof -nP -iTCP:53 -iUDP:53 -sTCP:LISTEN -Fpcn | tail -n +2)
if [ -n "$occupiers" ]; then
  echo "  以下进程/容器占用了端口 53："
  echo "$occupiers" | sed 's/^/    /'
  read -p "是否要停止这些进程/容器并继续？[y/N]: " yn
  case "$yn" in
    [Yy]* )
      echo "$occupiers" | while read line; do
        case "$line" in
          p*) pid=${line#p}; kill "$pid" && echo "    已终止进程 $pid" ;;
          c*) cid=${line#c}; docker rm -f "$cid" && echo "    已删除容器 $cid" ;;
        esac
      done
      ;;
    * )
      echo "  取消部署，请先释放端口后重试。" >&2
      exit 1
      ;;
  esac
else
  echo "  端口 53 未被占用。"
fi

# 4. 下载 docker-compose.yaml 与 update.sh
echo "[4/8] 下载 docker-compose.yaml 与 update.sh…"
cd ~/mosdns
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/docker-compose.yaml
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/update.sh
chmod +x update.sh
echo "  下载完成。"

# 5. 执行 update.sh
echo "[5/8] 执行 update.sh 更新规则…"
./update.sh
echo "  update.sh 执行完毕。"

# 6. 创建 rules-date 并新增 geoip_private.txt
echo "[6/8] 创建 rules-date 并新增 geoip_private.txt…"
mkdir -p rules-date
: > rules-date/geoip_private.txt

# 7. 创建 config 并下载配置文件及 rule 子目录
echo "[7/8] 创建 config 并下载配置文件…"
mkdir -p config/rule
cd config
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/config_custom.yaml
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/dns.yaml
wget -q https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/dat_exec.yaml
cd rule
: > whitelist.txt
: > greylist.txt
cd ~/mosdns

# 8. 启动 mosdns 容器
echo "[8/8] 启动 mosdns 容器…"
docker-compose up -d

echo "部署完成！使用 'docker-compose logs -f mosdns' 查看运行日志。"
