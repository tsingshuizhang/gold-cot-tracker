#!/bin/bash
# ============================================================
# 黄金 CFTC COT 追踪工具 - 执行脚本
#
# 用法:
#   ./run.sh                 交互菜单模式
#   ./run.sh latest          查看最新一期 COT 报告
#   ./run.sh history 52      抓取最近 52 周保存 CSV
#   ./run.sh chart 156       生成持仓走势图
#   ./run.sh dashboard 520   生成交互看板 dashboard.html + dashboard_ta.html
#   ./run.sh ta 520          只刷新技术分析页行情(增量, 不抓 COT 数据)
#   ./run.sh all             全部执行(默认 156 周)
# ============================================================

set -e
cd "$(dirname "$0")"

# ---------- 选择 Python 解释器 ----------
# 优先使用 Kimi Work 托管运行时(已验证可用), 否则回退到系统 python3
MANAGED_PY="$HOME/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/python/.venv/bin/python"
if [ -x "$MANAGED_PY" ]; then
    PY="$MANAGED_PY"
elif command -v python3 >/dev/null 2>&1; then
    PY="python3"
elif command -v python >/dev/null 2>&1; then
    PY="python"
else
    echo "[错误] 未找到 Python, 请先安装 Python 3"
    exit 1
fi

echo "使用解释器: $PY"
echo

# ---------- 带参数: 直接透传 ----------
if [ $# -gt 0 ]; then
    CMD="$1"; shift
    # 第二个参数视为周数
    if [ $# -gt 0 ]; then
        exec "$PY" gold_cot.py "$CMD" --weeks "$1"
    else
        exec "$PY" gold_cot.py "$CMD"
    fi
fi

# ---------- 无参数: 交互菜单 ----------
echo "=============================================="
echo "   黄金 CFTC COT 持仓追踪工具"
echo "=============================================="
echo "  1) 查看最新一期 COT 报告"
echo "  2) 抓取历史数据并保存 CSV (最近 52 周)"
echo "  3) 生成持仓走势图 (最近 156 周)"
echo "  4) 生成交互看板 dashboard.html + dashboard_ta.html (最近 10 年)"
echo "  5) 仅刷新技术分析页行情数据 (增量, 不抓 COT)"
echo "  6) 全部执行 (报告 + CSV + 图表)"
echo "  7) 退出"
echo "=============================================="
read -r -p "请选择 [1-7]: " choice

case "$choice" in
    1) "$PY" gold_cot.py latest ;;
    2) "$PY" gold_cot.py history --weeks 52 ;;
    3) "$PY" gold_cot.py chart --weeks 156 ;;
    4) "$PY" gold_cot.py dashboard --weeks 520
       command -v open >/dev/null 2>&1 && open dashboard.html ;;
    5) "$PY" gold_cot.py ta --weeks 520 ;;
    6) "$PY" gold_cot.py all --weeks 156 ;;
    7) echo "已退出"; exit 0 ;;
    *) echo "[错误] 无效选择: $choice"; exit 1 ;;
esac
