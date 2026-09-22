# 黄金 CFTC COT 持仓追踪工具

抓取美国 CFTC(商品期货交易委员会)官方发布的 COMEX 黄金期货 COT
(Commitments of Traders, 交易员持仓报告) 数据, 叠加金价、美元指数,
生成可交互的 HTML 持仓看板。

**在线网站(自动更新): <https://tsingshuizhang.github.io/gold-cot-tracker/dashboard.html>**
由 GitHub Actions 每天定时抓取数据并发布, 无需手动操作;
技术分析页在网站上每 60 秒自动重载最新行情数据。

## 数据来源

- **CFTC Socrata API**(官方, 免费, 无需密钥)
  - Disaggregated Futures Only: 数据集 `6dca-aqww`
  - Legacy Futures Only: 数据集 `jun7-fc8e`
- **CFTC 官方年度 zip**(备用源, Socrata 不可用时自动切换)
  - `fut_disagg_txt_{year}.zip` / `deacot{year}.zip`, 下载后缓存到 `data/cache/`
    (历史年份永久缓存, 当年缓存 12 小时)
- 黄金合约: `GOLD - COMMODITY EXCHANGE INC.`, CFTC 市场代码 `088691`
- 金价/美元指数: 东方财富 API 优先(黄金 `101.GC00Y`, 美元指数 `100.UDI`),
  Yahoo Finance (`GC=F` / `DX-Y.NYB`) 备用
- **黄金期权 PCR**: 上期所沪金期权官方日行情
  (`shfe.com.cn/data/tradedata/option/dailydata/kx{日期}.dat`), 主源;
  单线程顺序增量抓取 (并发高频请求会触发源站限流),
  休市日记入 gaps 缓存不再重复请求;
  美国黄金期权 PCR 来自 GLD 黄金ETF 期权链 (Yahoo, CBOE 上市, 流动性最好
  的美国黄金相关期权; COMEX 期货期权免费渠道不可用, 用 GLD 作情绪代理),
  best-effort (Yahoo 限流时自动降级, 看板隐藏该线)

 COT 报告每周五 15:30 ET 发布(数据截至当周周二)。

## 刷新与发布时点 (增量 + 发布后才刷新)

所有数据源遵循两条规则: **① 增量刷新** (已有历史绝不重复抓取);
**② 发布时点后刷新** (数据尚未发布的日期不请求, 避免无效抓取和误标)。

| 数据源 | 发布时间 | 刷新逻辑 |
|---|---|---|
| COT 持仓 | 每周五 15:30 ET (北京周六凌晨) | 磁盘缓存, 已覆盖最近一期已发布报告则整周跳过网络请求 |
| 黄金 OHLC / 美元指数 | 实时 (盘中未收盘 bar 也可抓) | 增量缓存, 每次只补抓最后几天尾部, 含盘中实时 bar |
| 沪金期权 PCR | 当日晚间约 20:00 (北京时间) | 增量 + gaps 缓存, 20:00 后可抓今天, 白天只到昨天 |
| 美国 GLD 期权 PCR | 美股收盘后 | 快照按**美股交易日**打戳 (非运行日), 缓存已有该日则跳过 |

GitHub Actions 两种定时: 每天北京时间 07:30 全量检查 (沪金/美股数据均已发布,
周六可抓周五发布的 COT); **美股交易时段每小时** (UTC 14-21 周一至五) 刷新
盘中实时行情, 配合技术分析页每 60 秒自动重载, 网站数据最迟 1 小时内更新。

## 安装

```bash
pip install -r requirements.txt   # 仅画图/金价需要; 纯抓取零依赖
```

## 用法

方式一: 执行脚本 (推荐)

```bash
./run.sh                 # 交互菜单
./run.sh latest          # 查看最新一期 COT 报告
./run.sh history 52      # 抓取最近 52 周保存 CSV
./run.sh chart 156       # 生成持仓走势图
./run.sh dashboard 520   # 生成交互看板 (默认 156 周)
./run.sh all             # 全部执行
```

macOS 用户也可以直接在访达中双击 `双击运行.command` 打开菜单。

方式二: 直接调用 Python

```bash
python gold_cot.py latest                # 查看最新一期 COT 报告解读
python gold_cot.py history --weeks 52    # 抓取最近 52 周, 保存 CSV 到 data/
python gold_cot.py chart --weeks 156     # 生成持仓 vs 金价走势图到 charts/
python gold_cot.py dashboard --weeks 520 # 生成 dashboard.html + dashboard_ta.html 两页看板
python gold_cot.py ta --weeks 520        # 只刷新技术分析页行情 (增量, 不抓 COT)
python gold_cot.py all                   # 一次全部执行
```

## 交互看板 (dashboard.html + dashboard_ta.html)

`python gold_cot.py dashboard` 一次生成两个可互相跳转的页面, 数据互相独立:

**持仓页 `dashboard.html`** (数据内嵌, 无需服务器):

1. **管理基金(机构大资金)净持仓 vs 金价** — 红/绿柱为净多/净空
2. **各类交易者净持仓对比** — 管理基金(机构大资金) / 生产商·贸易商(套保) /
   掉期交易商(做市) / 其他报告(中小投机) / 散户·非报告 五类资金对比
3. **管理基金多空分项** — 多头/空头持仓分别展示
4. **总持仓 Open Interest** — 市场总体热度
5. **金价 vs 美元指数 DXY** — 双轴对照
6. **黄金期权 PCR (看跌/看涨)** — 沪金期权成交量 PCR 与持仓量 PCR
   (上期所官方日频, 2024-03 起); 美国 GLD 期权 PCR (Yahoo 期权链) 可用时并列显示;
   灰色虚线为 PCR = 1 基准线, 高于 1 表示看跌成交/持仓多于看涨, 情绪偏空;
   点击图例**单独显示**某条沪金 PCR 时, 自动叠加 ±1σ 标准差上下轨
   (灰色虚线, 滚动 60 日窗口)

交互功能: 时间维度切换 (周/月/季/年, 月/季/年取周期最后一期)、
时间范围 (近 1/3/5 年/全部)、滚轮缩放 + 底部滑块、点击图例显隐分项。

**技术分析页 `dashboard_ta.html`** (独立数据文件 `data/ta_data.js`):

1. **K 线 + 布林带(20, 2) + 斐波那契回撤位** — 布林轨道为蓝色虚线、
   斐波那契为紫色虚线, 颜色明确区分; 回撤位基于可视区间自动计算, 缩放时实时重算;
   标注为黑色字位于右侧; 支持 **日K / 周K / 月K** 周期切换
   (聚合规则: 开=首, 收=末, 高=最高, 低=最低, 指标随周期联动重算)
2. **收盘价 + 均线** — MA5 / MA10 / MA20 / MA60 / MA120 / MA250
3. **金价 vs 行业平均开采成本 (AISC) + 金价/AISC 比值** —
   成本为年度估算值(右轴为比值, 虚线基准 1.0)
4. **MACD(12, 26, 9)** — 含 金叉 / 死叉 / 顶背离 / 底背离 标注

刷新机制:

- 页面每 **60 秒自动重载** `data/ta_data.js`, 也可点"**刷新数据**"按钮手动刷新;
  刷新只涉及本页行情文件, **不会重新抓取或影响持仓页的 COT 周度数据**
- 行情数据增量更新: `python gold_cot.py ta` (或 `./run.sh ta`) 只补齐
  缓存中缺失的日期, **已有历史数据绝不重复抓取**
  (缓存 `data/ta_ohlc.json`, 已覆盖到当天时直接跳过网络请求)

## MACD 信号判断标准

MACD 参数 (12, 26, 9), `DIF = EMA12 − EMA26`, `DEA = EMA(DIF, 9)`,
`MACD 柱 = 2 × (DIF − DEA)`。技术分析页按以下规则自动标注:

| 信号 | 判断标准 | 标注颜色 |
|---|---|---|
| **金叉** | DIF 由下向上穿越 DEA: 当日 DIF > DEA 且前一交易日 DIF ≤ DEA, 视为多头信号 | 红色 |
| **死叉** | DIF 由上向下穿越 DEA: 当日 DIF < DEA 且前一交易日 DIF ≥ DEA, 视为空头信号 | 绿色 |
| **顶背离** | 收盘价相邻两个摆动高点(左右各 5 根 K 线内的局部最高点)中后者高于前者, 而 DIF 在对应两个高点中后者低于前者 —— 价升动能减, 上涨衰竭风险提示 | 紫色 |
| **底背离** | 收盘价相邻两个摆动低点(左右各 5 根 K 线内的局部最低点)中后者低于前者, 而 DIF 在对应两个低点中后者高于前者 —— 价跌动能减, 下跌衰竭/反弹提示 | 蓝色 |

为避免标注过多糊住图表, 页面只显示**最近 60 个交叉信号**和**最近 12 个背离信号**;
标注同时出现在 MACD 面板 DIF 线上, 鼠标悬停可查看说明。背离为风险提示信号,
存在滞后与误判, 不构成投资建议。

## 输出

- `dashboard.html` — COT 持仓交互看板 (数据内嵌, 双击即可打开)
- `dashboard_ta.html` + `data/ta_data.js` — 技术分析页及其数据文件
- `data/ta_ohlc.json` — 黄金日频 OHLC 增量缓存 (已有数据不重复抓取)
- `data/dxy_daily.json` — 美元指数日频收盘价增量缓存 (同上策略)
- `data/gold_pcr_shfe.json` — 沪金期权 PCR 日频增量缓存 (磁盘永久保留全部历史)
- `data/gold_pcr_gld.json` — 美国 GLD 期权 PCR 缓存 (best-effort, 逐日累积)
- `data/gold_cot_disaggregated.csv` — 管理基金/生产商/掉期商分项持仓
- `data/gold_cot_legacy.csv` — 商业/非商业传统分类持仓
- `data/cache/` — CFTC 年度 zip 缓存
- `data/gold_cot_cache.json` — COT 持仓缓存 (已覆盖最近已发布报告时跳过网络请求)
- `charts/gold_cot_<日期>.png` — 净持仓、多空分项、总持仓三图合一

## 指标说明

| 字段 | 含义 |
|---|---|
| `mm_net` | 管理基金(投机/机构大资金)净持仓 = 多头 - 空头, 黄金最主要的方向性资金 |
| `pm_net` | 生产商/贸易商净持仓, 通常为净空(套保) |
| `swap_net` | 掉期交易商(做市对冲盘)净持仓 |
| `oth_net` | 其他报告(中小型投机商)净持仓 |
| `nr_net` | 非报告(散户/小机构)净持仓 |
| `*_wow` | 周环比变化 |
| `pct_oi_mm_long` | 管理基金多头占总持仓比例, 衡量拥挤度 |
| `PCR (成交量)` | 沪金期权看跌成交量 / 看涨成交量, >1 偏空, <1 偏多 |
| `PCR (持仓量)` | 沪金期权看跌持仓量 / 看涨持仓量, 变化更平缓, 反映中期情绪 |
