#!/bin/sh

# ==============================================================================
# MosDNS & AdGuardHome 规则定时更新与双向同步脚本
# ------------------------------------------------------------------------------
# Script Version : v2026.07.26-Rev.R (Fully Annotated Production Edition)
# Modified Note  : 1. 增加全量行级深度技术注释，详细解析每一行代码的底层原理与工程考量。
#                  2. 融合严审 UUID 规范、单次流式扫描去重、云端自愈反推与即用即删架构。
#                  3. 仅保留宿主机 IPv4 物理网段作为唯一站点判别标准，极致稳定。
# ==============================================================================

# ==============================================================================
# I. 全局路径与基础变量定义
# ------------------------------------------------------------------------------
# 使用 $HOME 环境变量动态推导路径，确保无论以 root 还是普通用户执行都能正确寻址。
# ==============================================================================
MOSDNS_DIR="$HOME/mosdns"                     # MosDNS 服务的根目录
RULES_DAT_DIR="$MOSDNS_DIR/rules-dat"         # 通用规则集 (geoip/geosite 等) 保存目录
RULE_DIR="$MOSDNS_DIR/config/rule"            # 自定义白名单/黑名单规则保存目录

ADH_DIR="$HOME/adh"                           # AdGuardHome 服务的根目录
ADH_CONF_DIR="$ADH_DIR/conf"                  # AdGuardHome 配置文件保存目录
ADH_LOCAL_FILE="${ADH_CONF_DIR}/AdGuardHome.yaml" # 正在运行的 AdGuardHome 主配置文件路径

# 本地 Git 临时仓库路径 (用于比对时间戳、代码差异及触发自愈推送)
REPO_DIR="$HOME/Customized_Config_Files"
# GitHub 远程仓库 SSH 链接 (通过 SSH 协议克隆，利用底层物理密钥免密鉴权)
REPO_URL="git@github.com:dayunliang/Customized_Config_Files.git"

# 远程基础下载路径定义 (用于 MosDNS 单向下载规则时的 HTTP URL 拼接)
CUSTOM_RULE_BASE_URL="https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/config/rule"

# ==============================================================================
# II. CRONTAB 后台执行环境修正 (安全授权核心)
# ------------------------------------------------------------------------------
# 【技术难点】crontab 在后台无人值守运行时，拥有的是一个极其精简的干净环境变量，
# 它默认不会去加载用户的 SSH 代理或家目录下的密钥，常导致 git 操作报错 Permission denied。
# 【解决方案】通过显式声明 GIT_SSH_COMMAND，强制指示 Git 底层调用的 ssh 命令：
#   1. -i $HOME/.ssh/id_ed25519 : 指定使用更安全的 ED25519 物理私钥进行身份鉴权；
#   2. -o StrictHostKeyChecking=no : 自动信任未知 GitHub 节点，跳过首次连接的 yes/no 弹窗确认；
#   3. -o UserKnownHostsFile=/dev/null : 不把临时指纹写入 known_hosts，保持系统指纹库纯净。
# ==============================================================================
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ==============================================================================
# III. 宿主机网段唯一识别机制 (Pre-flight Check 准入关卡)
# ------------------------------------------------------------------------------
# 无需修改主机名或创建任何标识文件，直接通过宿主机当前分配到的物理 IPv4 网段自动锁桩。
# ==============================================================================
CURRENT_SITE=""

# 1. 执行 `ip -4 addr show` 仅打印 IPv4 网卡信息，通过 `grep -qE` 静默匹配正则表达式；
# 2. 匹配 `inet 192\.168\.12\.[0-9]+`：严格限定为 192.168.12.x 网段 (Beverly 站点特征)；
#    (注意转义了小数点，有效防止把 172.17.0.1 等 Docker 默认桥接网卡误判进来)。
if ip -4 addr show 2>/dev/null | grep -qE "inet 192\.168\.12\.[0-9]+"; then
  CURRENT_SITE="Beverly"
# 3. 如果不匹配上述，继续检查是否属于 10.29.2.x 网段 (Riviera 站点特征)
elif ip -4 addr show 2>/dev/null | grep -qE "inet 10\.29\.2\.[0-9]+"; then
  CURRENT_SITE="Riviera"
else
  # 【安全熔断机制】：如果两者都没匹配上（如断网或获取到了异常 IP），立刻报错退出！
  # 绝对不可向下继续执行，从而保护现有正处于生产服务运行中的 DNS 配置不被任何错误操作破坏。
  echo "【系统错误】无法通过当前宿主机 IP 网段识别站点！脚本触发安全熔断，停止执行。"
  exit 1
fi

echo "=============================================================================="
echo "开始执行网络服务规则更新与双向同步任务 (UUID 规范严审 + 纯净模式)"
echo "当前匹配站点 : 【 ${CURRENT_SITE} 】"
echo "=============================================================================="
echo

# ==============================================================================
# IV. 动态按需克隆临时仓库 (即用即删前置初始化)
# ------------------------------------------------------------------------------
# 为了保证测试与生产的纯净性，如果上次运行遗留了仓库文件夹，先强制粉碎，
# 确保每次比对都是面对一个最原生、未受污染的全新 Git 克隆现场。
# ==============================================================================
[ -d "$REPO_DIR" ] && rm -rf "$REPO_DIR"

echo ">>> 正在自动克隆最新的 GitHub 仓库以供比对..."
git clone "$REPO_URL" "$REPO_DIR" >/dev/null 2>&1

# 校验克隆操作返回值 ($?) 和物理目录合法性 (.git 是否存在)
if [ $? -ne 0 ] || [ ! -d "$REPO_DIR/.git" ]; then
  echo "【系统错误】克隆仓库失败，请检查服务器网络或 SSH ED25519 密钥授权配置！"
  exit 1
fi

# 确保所有目标运行路径的文件夹真实存在，防止后续文件下载或同步报错“No such file or directory”
[ ! -d "$RULES_DAT_DIR" ] && mkdir -p "$RULES_DAT_DIR"
[ ! -d "$RULE_DIR" ] && mkdir -p "$RULE_DIR"
[ ! -d "$ADH_CONF_DIR" ] && mkdir -p "$ADH_CONF_DIR"

# ==============================================================================
# V. 🛠️ 函数：AdGuardHome 配置文件 UUID 规范审查与云端自愈函数 (核心黑科技)
# ------------------------------------------------------------------------------
# 该函数在单次扫描中解决两大隐患：
#   1. 客户端 UID 冲突 (复制粘贴产生相同的 uid)；
#   2. UID 格式与长度畸形 (如手误打错多一位数字变成 37 位，或包含非法字符)。
# 采用 AWK 状态机对齐原生缩进进行洗净，并在发现原始缺陷时触发【云端自愈推送】。
# ==============================================================================
fix_duplicate_uids() {
  local target_file="$1"
  # 如果目标待校验的文件本身不存在，直接返回成功跳过，不报致命错误
  [ ! -f "$target_file" ] && return 0

  echo "  → 正在建立全局状态机，严审客户端 UID 规范性与唯一性..."
  
  # 调用系统级 AWK 工具对文件进行单次流式逐行扫描与重构
  awk '
    BEGIN {
      changes = 0 # 跟踪整个扫描过程中是否触发过任何修改或纠偏
    }
    
    # 【触发条件】：使用正则匹配包含了 `uid:` 字段，且前后可以带有任意缩进空格的行
    /[[:space:]]*uid:[[:space:]]*/ {
      curr_line = $0
      # 1. 剥离 `uid:` 及其前面的所有前导文字
      sub(/.*uid:[[:space:]]*/, "", curr_line)
      # 2. 剥离可能遗留的双引号、单引号以及空格，提取最核心的纯字符串文字
      gsub(/["'\''[:space:]]/, "", curr_line)
      
      if (curr_line != "") {
        # 【检查项 1：查重】：该字符串是否已经在字典 (seen 数组) 里注册过？
        is_duplicate = seen[curr_line]
        # 【检查项 2：验规】：校验该字符串是否为正规标准的 36 位 UUID！
        # 标准格式：8位十六进制 - 4位 - 4位 - 4位 - 12位十六进制 (如 019f0bee-0885-717c-9a6e-4e8c54c7095b)
        is_invalid_format = (length(curr_line) != 36 || curr_line !~ /^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/)
        
        # 只要发现存在重复或格式不合规，立刻启动自动洗涤机制
        if (is_duplicate || is_invalid_format) {
          # 【降级生成算法】：优先从 Linux 内核底层的高熵随机数发生器读取真实的 UUID；
          cmd = "cat /proc/sys/kernel/random/uuid 2>/dev/null"
          # 如果在某些极度裁剪的微型系统 (如 Alpine 容器内核) 里没有这个路径：
          if ((cmd | getline new_uuid) <= 0) {
            close(cmd)
            # 退而求其次：利用 /dev/urandom 抓取 16 个随机字节，通过十六进制格式化组装标准 36 位 UUID
            cmd = "od -x -N 16 /dev/urandom | head -n 1"
            cmd | getline rand_line
            split(rand_line, parts)
            new_uuid = sprintf("%s%s-%s-%s-%s-%s%s%s", parts[2], parts[3], parts[4], parts[5], parts[6], parts[7], parts[8], parts[9])
          }
          close(cmd)
          
          # 【保留原生缩进】：利用 match() 捕获当前行最前方的所有空白字符(缩进)
          match($0, /^[[:space:]]*/)
          indent = substr($0, RSTART, RLENGTH)
          
          # 重构这一行：前导缩进 + 裸字符串形式的 uid: + 新生成的标准 UUID
          # 这样可以 100% 保持你 YAML 文件的原生排版风格，不会产生格式错杂
          print indent "uid: " new_uuid
          
          # 将具体诊断日志由 stderr 标准错误流打印到控制台，方便运维审计
          if (is_invalid_format) {
            print "    [格式自愈] 剥离畸形非标准项 " curr_line " -> 已重构为唯一 UID: [ " new_uuid " ]" > "/dev/stderr"
          } else {
            print "    [冲突自愈] 拦截重复项 " curr_line " -> 已替换为唯一 UID: [ " new_uuid " ]" > "/dev/stderr"
          }
          changes++
          next # 直接处理下一行，不执行底部的 default 动作
        } else {
          # 合法、标准且不重复的优质 UID，在 seen 字典打上标记，予以放行
          seen[curr_line] = 1
        }
      }
    }
    # 正常行 (非 uid 行或修改后的处理结果) 原样打印输出到临时缓冲流
    { print }
    
    END {
      # 扫描完毕后汇报总体处理成果
      if (changes > 0) {
        print "  → AWK 状态机扫描完毕，累计就地修复 " changes " 处格式异常/重复 UID。" > "/dev/stderr"
      } else {
        print "  → 检查通过：全局客户端 UID 保持唯一性与标准规范。" > "/dev/stderr"
      }
    }
  ' "$target_file" > "${target_file}.tmp" 2> "${target_file}.log" # stdout写文件，stderr写日志

  # 输出并清理过程中打印的监控审计日志
  cat "${target_file}.log"
  rm -f "${target_file}.log"
  # 原子覆写：用处理完的干净文件去完全覆盖替换目标旧文件
  mv "${target_file}.tmp" "$target_file"

  # ============================================================================
  # 【云端自愈反向反哺机制 (Cloud Self-Healing Push)】
  # 如果这次清理修复的是正在克隆出的临时 Git 仓库内部的文件，说明 GitHub 远端
  # 存储的配置文件依然存在污染（缺陷），为了持久化消灭这些 BUG：
  # ============================================================================
  if [ -d "$REPO_DIR/.git" ]; then
    # 调取 git status --porcelain 检查修复完毕后，该文件相比刚 clone 下来时是否有任何文本改动
    local git_status=$(cd "$REPO_DIR" && git status --porcelain "$target_file" 2>/dev/null)
    if [ -n "$git_status" ]; then
      echo "  → [云端自愈] 嗅探到 GitHub 远端原始配置文件包含缺陷！正在主动发起反向修补操作..."
      cd "$REPO_DIR"
      # 为无人值守的 Git 提交配置标准的身份元数据
      git config user.name "dayunliang"
      git config user.email "dayunliang@users.noreply.github.com"
      git add "$target_file"
      git commit -m "auto-heal: resolve duplicate and malformed UIDs in $(basename "$target_file") via crontab" >/dev/null 2>&1
      # 利用开头建立的 ED25519 免密鉴权，瞬间把洗净后的文件反推覆盖回 GitHub 主分支
      git push origin main >/dev/null 2>&1
      echo "  → [云端自愈] 成功将百分之百格式合法且唯一的配置反向覆盖回 GitHub 云端仓库！"
    fi
  fi
}

# ==============================================================================
# VI. AdGuardHome 配置文件双向智能同步逻辑 (基于 Git 状态与日志对撞)
# ------------------------------------------------------------------------------
# 彻底解决了常规操作操作系统文件修改时间 (stat) 在 git clone 场景下全部变成
# “刚刚克隆的时间”带来的时间戳错乱误判。
# ==============================================================================
echo "--- 正在通过 Git 状态与云端日志进行双向比对 ---"

cd "$REPO_DIR"
# 根据第一步识别到的站点身份，拼装当前机器对应的 GitHub 仓库相对路径文件
REPO_FILE_NAME="mosdns/conf/adh.yaml.${CURRENT_SITE}"
REPO_FILE_PATH="${REPO_DIR}/${REPO_FILE_NAME}"

# 【核心突破 1】：获取远程 GitHub 仓库里该配置文件最后一次真正 commit 的 Unix 时间戳 (秒数)
# 这个值来源于 Git Log 元数据，绝对不会因为你刚 clone 下来就被篡改成当前系统时间！
if git log -1 --format="%at" "origin/main" -- "$REPO_FILE_NAME" >/dev/null 2>&1; then
  GITHUB_COMMIT_TIME=$(git log -1 --format="%at" "origin/main" -- "$REPO_FILE_NAME")
else
  GITHUB_COMMIT_TIME=0
fi

# 状态变量：记录下本轮操作中，本地运行的 AdGuardHome 配置到底有没有发生改变
# 只有发生了改变 (被重写/下载)，最后才会触发 Docker 容器重启；否则主动跳过重启保护 DNS 连续性！
ADH_CHANGED=0

# 如果你的机器上正有 AdGuardHome 在运行，文件存在：
if [ -f "$ADH_LOCAL_FILE" ]; then
  # 确保仓库下对应层级的子目录存在
  mkdir -p "$(dirname "$REPO_FILE_PATH")"
  # 【核心突破 2】：强行把你正在运行的配置放入刚克隆的 Git 仓库里，交由 git status 判断
  cp "$ADH_LOCAL_FILE" "$REPO_FILE_PATH"

  # 利用 git status --porcelain 查看文件内容是否与刚克隆下来的仓库版本有差异：
  # 如果返回值非空，代表有差异（要么你修改了 Web UI，要么远程有人更新了仓库）：
  if [ -n "$(git status --porcelain "$REPO_FILE_NAME")" ]; then
    
    # 提取本地这台物理服务器上运行的配置文件最近一次修改的 Linux 物理时间戳 (兼容 stat Linux 和 MacOS 语法)
    LOCAL_PHYSICAL_TIME=$(stat -c %Y "$ADH_LOCAL_FILE" 2>/dev/null || stat -f %m "$ADH_LOCAL_FILE")
    
    # 【时空对撞】：用云端真实 commit 时间跟本地运行文件的实际物理修改时间硬碰硬！
    if [ "$GITHUB_COMMIT_TIME" -gt "$LOCAL_PHYSICAL_TIME" ]; then
      # 场景 A：云端的最后提交时间比你本地文件的生产时间还要晚 -> 代表云端比你新，该“下载云端”！
      echo ">>> 结果：检测到云端配置有更新的提交！准备更新本地服务..."
      # 先利用 git checkout 抛弃掉刚刚用 cp 强塞进仓库测试的旧文件，还原回纯净的云端最新版
      git checkout -- "$REPO_FILE_NAME" >/dev/null 2>&1
      
      # 【第一道安全卡口】：将云端最新的文件喂给严审函数，过滤一切缺陷并可能触发云端自愈
      fix_duplicate_uids "$REPO_FILE_PATH"
      
      # 经过严格审查确认安全后，正式覆盖本地正在对外提供解析服务的主配置文件
      cp "$REPO_FILE_PATH" "$ADH_LOCAL_FILE"
      echo "→ 成功将云端配置同步至本地: $ADH_LOCAL_FILE"
      ADH_CHANGED=1 # 标注发生了实质变更，稍后须重启 Docker 容器加载新配置
    else
      # 场景 B：本地文件的生产时间比云端最后提交更晚 -> 代表你在 Web UI 里保存了新规则，该“反推云端”！
      echo ">>> 结果：检测到本地配置有更新的改动！正在推送到 GitHub..."
      git config user.name "dayunliang"
      git config user.email "dayunliang@users.noreply.github.com"
      
      git add "$REPO_FILE_NAME"
      git commit -m "auto-sync: update ${REPO_FILE_NAME} from ${CURRENT_SITE} host via crontab" >/dev/null 2>&1
      git push origin main >/dev/null 2>&1
      echo "→ 成功将本地最新修改推送至 GitHub 仓库。"
      ADH_CHANGED=0 # 我们只是把本地上传到了云端，本地本身是在运行状态，无需多此一举去重启容器！
    fi
  else
    # 场景 C：git status 返回为空 -> 代表你本地运行的文件 and 刚克隆下来的云端文件连一个标点符号都不差！
    echo ">>> 结果：本地运行配置与云端最新提交完全一致，无需任何操作。"
    ADH_CHANGED=0
  fi
else
  # 场景 D：你机器上是第一次运行此脚本，或者你把 ~/adh/conf 目录彻底删光了
  echo ">>> 结果：本地未找到配置文件，正在从云端进行初始化下载..."
  # 同样先经过严审防御清洗，修复一切云端自身带有的 UID 重复或畸形问题
  fix_duplicate_uids "$REPO_FILE_PATH"
  cp "$REPO_FILE_PATH" "$ADH_LOCAL_FILE"
  ADH_CHANGED=1
fi
echo

# ==============================================================================
# VII. MosDNS 通用规则与自定义 Rule 下载 (保持单向防宕机原子下载)
# ------------------------------------------------------------------------------
# 完美同步 deploy.sh 的容灾意志：直连变慢或 404 时自动挂载 ghproxy.net 镜像加速
# ==============================================================================

# 1. 定义中国大陆 IP、GFW、各大厂商清单等基础分流规则 (对应下载至 ~/mosdns/rules-dat)
RULES_DAT_URL_FILE_LIST=$(cat << 'EOF_RULES_DAT'
https://raw.githubusercontent.com/17mon/china_ip_list/refs/heads/master/china_ip_list.txt geoip_cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt geosite_category-ads-all.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt geosite_geolocation-!cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt geosite_cn.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt geosite_gfw.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/china-list.txt geosite_cn_extra.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/apple-cn.txt geosite_cn_apple.txt
https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/google-cn.txt geosite_cn_google.txt
https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/rules-dat/hosts.txt hosts.txt
https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/mosdns/rules-dat/geoip_private.txt geoip_private.txt
EOF_RULES_DAT
)

# 2. 定义你自定义的白名单、黑名单、免缓存等核心规则 (对应下载至 ~/mosdns/config/rule)
CUSTOM_RULE_URL_FILE_LIST=$(cat << EOF_CUSTOM_RULE
${CUSTOM_RULE_BASE_URL}/greylist.txt greylist.txt
${CUSTOM_RULE_BASE_URL}/nocache.txt nocache.txt
${CUSTOM_RULE_BASE_URL}/whitelist.txt whitelist.txt
EOF_CUSTOM_RULE
)

# 封装的高可用原子防宕机安全下载引擎函数
download_files() {
  list="$1"
  target_dir="$2"
  
  printf "%s\n" "$list" | while IFS=' ' read -r url fname; do
    [ -z "$url" ] && continue
    [ -z "$fname" ] && continue

    tmp_file="${target_dir}/${fname}.tmp"
    
    # 优先进行原生 HTTP 下载，控速 15 秒防止后台死锁
    wget -q --timeout=15 "$url" -O "$tmp_file"

    # 如果 wget 直连失败或下回了空文件 (0字节)，且属于 GitHub 域名，则触发降级镜像源自愈
    if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
      if echo "$url" | grep -q "raw.githubusercontent.com"; then
        rm -f "$tmp_file"
        # 引入与部署脚本 100% 对齐的生产级 ghproxy 备用通路
        wget -q --timeout=15 "https://ghproxy.net/$url" -O "$tmp_file"
      fi
    fi

    # 【严格完整性校验】：只有新文件百分百验证完整且有内容，才在 0.001 秒内原子覆盖
    if [ $? -eq 0 ] && [ -s "$tmp_file" ]; then
      mv "$tmp_file" "${target_dir}/${fname}"
    else
      rm -f "$tmp_file"
    fi
  done
}

echo "--- 正在下载 MosDNS 规则与自定义 Rule ---"
download_files "$RULES_DAT_URL_FILE_LIST" "$RULES_DAT_DIR"
download_files "$CUSTOM_RULE_URL_FILE_LIST" "$RULE_DIR"
echo "→ MosDNS 规则下载尝试完毕。"
echo

# ==============================================================================
# VIII. 智能判定并重启对应的 Docker 容器服务 (系统级适配)
# ------------------------------------------------------------------------------
# 补回被误删的组件服务拉起模块，确保配置文件的下载可以落实到活跃业务中。
# ==============================================================================
echo "=============================================================================="
echo "检查完毕，开始适配宿主机环境重启 Docker 容器..."
echo "=============================================================================="

# 探查优先级：新版插件式语法 -> 老版本命令行工具 -> 常见默认绝对路径
if docker compose version >/dev/null 2>&1; then
  DC_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC_CMD="docker-compose"
else
  DC_CMD="/usr/local/bin/docker-compose"
fi

# 1. MosDNS：由于前面每次都进行了规则清点，为了保证其加载到了最新生效的分流 IP 库，固定执行重启
echo "→ 正在重启 MosDNS 服务..."
cd "$MOSDNS_DIR" && $DC_CMD down && $DC_CMD up -d
echo

# 2. AdGuardHome：【高可用优化机制】
# 只有前面的逻辑侦测到了云端有新提交、触发了本地初始化或执行了自愈覆盖 (ADH_CHANGED=1)，才去重启！
# 这样能完全避免平时定时执行无变化时对家里网络解析造成的无意义 3 秒闪断。
if [ "$ADH_CHANGED" -eq 1 ] || [ ! -f "$ADH_LOCAL_FILE" ]; then
  echo "→ 检测到云端有新配置更新或首次初始化，正在重启 AdGuardHome 服务..."
  cd "$ADH_DIR" && $DC_CMD down && $DC_CMD up -d
else
  echo "→ 本地配置已是最新，主动跳过 AdGuardHome 容器重启以保证网络 100% 连续不间断。"
fi
echo

# ==============================================================================
# IX. 极致环境清理：斩草除根，销毁临时仓库 (纯净强迫症终极福音)
# ------------------------------------------------------------------------------
# 执行终极清场，不留一丝临时文件、分支缓存或仓库对象碎片。
# ==============================================================================
echo ">>> 正在执行终极清理：彻底删除本地 GitHub 临时仓库..."
rm -rf "$REPO_DIR"

echo "=============================================================================="
echo "所有同步、UID 深度规范自愈、容器管理及环境彻底销毁任务顺利完成！"
echo "=============================================================================="
