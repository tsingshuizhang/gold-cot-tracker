#!/bin/bash
# macOS 访达双击入口: 打开交互菜单
cd "$(dirname "$0")"
bash run.sh
echo
read -r -p "按回车键关闭窗口..."
