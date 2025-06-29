Lean 源码根目录下，直接运行下面的命令即可一键同步：

# 推荐用 curl，直接在 Lean 源码根目录下运行
curl -fsSL https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/Lean/deploy_custom_files.sh | bash

或者用：

wget -O https://raw.githubusercontent.com/dayunliang/Customized_Config_Files/refs/heads/main/Lean/deploy_custom_files_test.sh | bash

自动流程：

脚本会自动 clone 下你的定制仓库到临时目录

自动把所有文件安全分发到对应位置

自动备份所有被覆盖的文件

全流程零手工，无需多余操作！
