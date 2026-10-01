# Process — 项目接续工作手册

> 本文件在**每次任务时更新**，配合 README.md，保证任何一次会话中断后，下一个会话（人或 AI）能
> 零成本接续。最后更新：2026-10-01（会话：浏览器实时源切东财 JSONP、App 同步改造+真机重装）。

## 一句话项目

抓取 CFTC 黄金 COT 持仓 + 金价/美元指数/期权 PCR，产出：
① 网页看板 `dashboard.html`、② 网页技术分析页 `dashboard_ta.html`（GitHub Pages 线上自动更新）、
③ iOS App `GoldCotTracker`（SwiftUI，已装用户真机）。

## 仓库结构

```
gold_cot.py              # 唯一数据流水线: 抓取→缓存→生成网页与数据文件
dashboard_template.html  # 看板模板（改网页必须改模板，再用数据注入生成 dashboard.html）
dashboard_ta_template.html # 技术分析页模板（同理生成 dashboard_ta.html）
dashboard.html / dashboard_ta.html  # 生成产物（含注入数据，与模板同步修改）
echarts.min.js           # 本地内置 ECharts 5.5（勿改回 CDN，用户网络访问 jsdelivr 不稳定）
data/                    # cot_data.json / ta_data.js / ta_ohlc.json / 各类缓存（Actions 定时提交）
app/                     # iOS App 全部源码 + XcodeGen 工程
  Sources/               # GoldCotTrackerApp.swift(Tab入口) / DashboardView / TAView /
                         # ChartViews.swift(Panel/RangeSlider/LegendToggle/MultiLineCanvas/MacdCanvas/YAxisLabels/ChartTooltip)
                         # CandleChartView / Indicators.swift(指标计算, 含边界保护) / DataStore.swift(抓取+本地缓存)
  project.yml            # XcodeGen 配置（改工程配置改这里，勿手改 pbxproj）
.github/workflows/update.yml  # 定时更新: 每天 UTC 23:30 全量 + 美股时段每小时刷新行情
```

## 数据节奏（排查"数据没更新"先读这里）

- **COT 周报**：每周五 15:30 ET 发布，数据截至**当周周二**。例：9/22(二) 的报告 9/25(五) 发布，
  线上"最新报告 2026-09-22"是正常断面，不是故障。下一期永远在下周五。
- **COMEX 黄金行情 / 技术分析页 K线**：日频收盘数据；美股收盘后 Actions 更新。不是逐笔实时。
  页面顶部<b>伦敦金 XAU/USD 与 COMEX GC 实时报价</b>来自新浪财经快照，每 10 秒自动刷新，
  作为日频 K线的补充。
- **上海黄金 T+D AUTD**：东方财富 `118.AUTD` 实时快照；因该源不支持跨域 JSONP，
  浏览器实时页会优先尝试东方财富 JSONP，失败时回落到 Actions 生成的静态快照（`data/rt_quotes.js`）。
- **realtime.html 图表数据**：`data/rt_charts.js`（Actions 生成）含三个品种日K历史
  —— gc 用 `ta_ohlc.json`（真实）、xau 优先 Yahoo `XAUUSD=X`（缓存 `data/xau_ohlc.json`，
  失败时 COMEX 形态 × 实时比价折算, 页面显示橙色提示）、sge 用东财 `118.AUTD` K线
  （缓存 `data/sge_ohlc.json`）。页面每 10 秒把实时报价合成"当日未收盘 bar"追加到K线末端。
- **沪金期权 PCR**：上期所官方日频，休市日不更新；国庆/春节等长假会断档数日。
- **美国 GLD 期权 PCR**：来自 Yahoo 期权链快照，经常限流/不可用，看板会自动隐藏。
- 本地 `data/` 可能比线上旧（本地只在手动跑 `python gold_cot.py dashboard --weeks 520` 时更新），
  **线上以 Actions 提交为准**。本地 file:// 预览想刷新就手动跑该命令（依赖 `pip install yfinance curl_cffi`）。

## 统一数据架构（三页面共用, 禁止分散维护）

`gold_cot.py` **同一次运行**生成下列全部数据文件, 三页面只是消费方, 不存在多份拷贝:

| 文件 | 内容 | 消费页面 |
|---|---|---|
| `data/rt_charts.js` (`window.RT_CHARTS`) | K线主数据: `gc`(COMEX真实) / `xau`(Yahoo优先,兜底折算) / `sge`(东财,兜底折算) | 技术分析页 + 实时行情页 |
| `data/rt_quotes.js` (`window.RT_QUOTES`) | 实时报价主数据: xau / gc / sge 快照 | 技术分析页报价条 + 实时行情页 |
| `data/ta_data.js` (`window.TA_DATA`) | 仅本页常量: 开采成本 AISC | 技术分析页 |
| `data/cot_data.json` → 注入 `dashboard.html` | COT 持仓 + 价格线 + DXY + PCR (构建期嵌入) | COT 持仓页 |

- 增量缓存: `ta_ohlc.json`(COMEX) / `xau_ohlc.json` / `sge_ohlc.json`, 互相独立补齐。
- **改行情数据结构只改 `write_rt_charts/write_rt_quotes` 一处**, 两个消费页自动同步。
- realtime.html 图表: 日K + MA5/10/20/60/100 (图例显示最新值, 可点按显隐) + MACD(12,26,9);
  每 10 秒用实时报价合成"当日未收盘 bar"更新K线末端。

- **浏览器端实时行情源**: 新浪 `hq.sinajs.cn` 校验 Referer(只允许 *.sina.com.cn),
  跨域 `<script>` 引用一律 403 —— **浏览器端必须用东方财富 ulist JSONP**
  (`push2.eastmoney.com/api/qt/ulist.np/get?secids=122.XAU,101.GC00Y,118.AUTD&fields=f2,f3,f4,f12,f14,f15,f16,f17,f18&cb=回调名`,
  f2=最新价 f3=涨跌幅% f4=涨跌额 f15=最高 f16=最低 f17=今开 f18=昨收; 部分字段原值放大100倍需归一)。
  **`<script>` 元素必须设 `referrerPolicy='no-referrer'`, 否则东财也校验 Referer 拦截(2026-10-01 踩过)**。
  App (URLSession) 默认不带 Referer, 可直接访问同一接口 (DataStore.refreshRtQuotesLive, 10秒轮询)。
  服务端 (gold_cot.py) 仍用新浪 urllib(带 Referer 头) + 东财 ulist 兜底。
- **App 实时页**: `RealtimeView` 放在 `TAView.swift` 末尾(独立文件需 xcodegen 重生工程,
  本机 XcodeGen.zip 是坏文件"Not Found"; 网络恢复后应 `brew install xcodegen` 修正);
  第三 Tab "实时行情", 卡片切换三品种 + 日K + MACD, 当前 bar 由实时报价合成。

## GitHub Actions `update.yml` 维护

- 工作流：**每天 UTC 23:30 全量 + 美股时段每小时刷新行情**。
- 2026-09-28 发现工作流出现 `exit code 1` 失败（Node 20 提示只是弃用警告，非根因）。
  根因待查：很可能是 yfinance 被限流 / 东方财富对 GitHub IP 不稳定。
- 已改造：抓取步骤改为 `continue-on-error: true`，输出用 `tee` 写入 `data/last_update.log`，
  提交步骤 `if: always()` 保证**失败时日志也提交到仓库**（便于本地排查）。
- 已新增新浪实时行情作为技术分析页实时报价源，降低对 yfinance 的依赖。
- actions 版本已从 `checkout@v4 / setup-python@v5` 升到 `checkout@v5 / setup-python@v6`。
- 排查时若再次出现失败，直接拉取仓库看 `data/last_update.log` 即可定位。

## iOS App 开发与安装

```bash
# 模拟器构建（快迭代用这个验证 UI）
xcodebuild -project app/GoldCotTracker.xcodeproj -scheme GoldCotTracker \
  -configuration Debug -sdk iphonesimulator build \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES
# 安装+截图验证
SIM=FE323DBE-E1BE-477C-A82E-559B79DC65D9
xcrun simctl install $SIM ~/Library/Developer/Xcode/DerivedData/GoldCotTracker-*/Build/Products/Debug-iphonesimulator/GoldCotTracker.app
xcrun simctl launch $SIM com.tsingshuizhang.GoldCotTracker
xcrun simctl io $SIM screenshot out.png
xcrun simctl openurl $SIM "http://localhost:端口/页面#chart"   # Safari 验证网页（加锚点直达图表区）

# 真机构建+安装（用户机器已配置好）
xcodebuild -project app/GoldCotTracker.xcodeproj -scheme GoldCotTracker \
  -configuration Debug -destination 'platform=iOS,id=<手机UDID>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=MQM879TDKM CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES build
xcrun devicectl device install app --device <手机UDID> \
  ~/Library/Developer/Xcode/DerivedData/GoldCotTracker-*/Build/Products/Debug-iphoneos/GoldCotTracker.app
```

- **签名团队**：`MQM879TDKM`（Apple ID tsingshui@hotmail.com，个人免费账号）。
  注意证书 CN 括号里的 M4342XHZX7 是错的，OU 字段才是团队 ID。
- **免费账号 7 天过期**：真机 App 到期打不开，重新跑上面两条命令即可（手机上已信任过证书不用重设）。
- 用户真机：iPhone 17 Pro Max，UDID `00008150-001129390E62401C`。
- **2026-09-28 真机安装遇 `com.apple.dt.CoreDeviceError 4016`**：`The device is not able to fulfill the requested usage assertion requirements.`
  通常是手机**锁屏/熄屏/忙**导致；解锁并保持亮屏后重试即可。源码已更新（发布日期卡片）。

## 网页开发要点（血泪经验，勿重蹈）

1. **改网页 = 改模板 + 改生成页**：两处文本一致，补丁脚本对 4 个文件同时打。改完用 node 验证：
   `node --check` 提取的 inline script（见"调试手法"）。
2. **ECharts 已本地内置**：`<script src="echarts.min.js">`。用户网络对 jsdelivr/境外 CDN 不稳定，
   不要再引入在线依赖。
3. **⚠️ `chart.getOption()` 首次返回 `undefined`**：在 setOption 之前调用会抛 TypeError 并导致
   整页图表空白（线上事故过）。写法必须是 `((chart.getOption() || {}).dataZoom || [])`。
   重绘保留 dataZoom 区间用的就是这个模式。
4. 手机端判定 `narrow` 用 `window.innerWidth < 768 || innerHeight < 500`，
   与 CSS 媒体查询 `(max-width:768px),(max-height:500px)` 保持一致（横屏覆盖）。
5. 手机端 resize（地址栏收放）**不得整体重绘**（会重置用户选中的时间区间）——只宽度变化才 render。
6. dataZoom 的 start/end 是**时间跨度百分比**，按时间映射回日期，不能按索引。
7. 每次渲染后 `updateZoomLabel()` 刷新滑块上方的"选中区间"文字。

## iOS 端关键设计（当前架构，改动前先理解）

- 图表全部 **SwiftUI Canvas 手绘**（曾用 Swift Charts 渲染 2600 点直接卡死主线程，永久弃用）。
- **Canvas 内严禁逐帧画 Text**（坐标刻度/斐波那契文字全走 SwiftUI overlay / YAxisLabels）——
  这是拖动流畅的命脉。MACD 金叉死叉文字限最近 10 个。
- **RangeSlider**：手势挂在静止滑轨上用绝对坐标（挂移动滑块上会漂移）；滑块实时跟手、
  图表提交限流 17Hz；双击复位；上方显示区间文字。
- **结果缓存**：TAView/DashboardView 的聚合序列+时间域在 @State 缓存（recomputeBase），
  只在数据/周期变化时重算，拖动每帧零重算。
- TA 页 4 图共享显式 X 轴（xDomain=window）；看板 6 图各用自身数据范围（PCR 数据 2022 年才有，
  共享全局限会挤压成竖线——这个坑已踩过）。
- **Indicators 有边界保护**：boll/macd 数据不足 n 条时返回空（`19..<5` 非法区间崩溃事故过）。
- 深色模式：全部用系统自适应色（systemBackground/secondary），禁止写死白色/灰色（事故过）。
- DataStore.refresh()：先读磁盘缓存立即显示，再联网刷新并落盘（caches 目录）。
- 真机构建必须带 `CODE_SIGNING_ALLOWED=YES`（工程 pbxproj 里默认 NO，模拟器时代的遗留）。

## 已知环境坑

- **这台 Mac 访问 GitHub 极不稳定**：push 经常 5-10 次才成功（Empty reply / 443 超时），
  push 必须带重试循环；不要误判为代码问题。
- 模拟器 `iPhone 18 Pro` UDID FE323DBE-E1BE-477C-A82E-559B79DC65D9（截图验证主力）。
- 无 gh/Chrome；网页验证靠"模拟器 Safari + localhost python http.server + openurl + 截图"。
- node 可用于 JS 语法检查与 ECharts SSR 冒烟（SSR 在 node 会偶发挂死，仅作语法/逻辑参考）。

## 调试手法（没有浏览器控制台时的三板斧）

1. `node --check`：提取 `<script>` inline 源码做语法检查。
2. node + DOM stub + ECharts SSR：跑页面主脚本抓异常（harness 模式见 git 历史 498e005 前后）。
3. 模拟器 Safari + `#锚点` 直达图表区截图。

## 提交前检查清单

- [ ] 网页 4 文件（2 模板 + 2 生成页）同步修改，node --check 通过
- [ ] App 模拟器构建通过、截图确认图表区/图例/滑块渲染正常
- [ ] 改了数据逻辑 → 确认 Actions workflow 的 cron/命令不需要同步调整
- [ ] 更新本文件 + README.md
- [ ] push 带重试循环，确认 `main -> main` 再收工

## 当前状态

- 线上（GitHub Pages）：两页图表/手机端图例/区间标签/时间复位/离线 ECharts 全部正常；
  COT 卡片以 CFTC 报告日期 2026-09-22 为主；
  技术分析页顶部实时报价条正常；COMEX 日频 K线已追平至 **2026-09-30**，
  之前卡在 9/28 是因为 `gold_cot.py` 漏 `import re` 导致 `ta_data.js` 生成失败；
  **新增 `realtime.html` 贵金属实时行情页**，展示伦敦金/COMEX/上金 T+D，每 10 秒刷新。
- App：真机版已更新至 2026-10-01 晚构建（约 10/8 到期）：
  DataStore 读统一数据源 + **东财直连 10 秒轮询实时报价**; 三个 Tab:
  持仓看板(含实时报价条) / 技术分析(MA100) / **实时行情(RealtimeView, 与网页 realtime.html 同功能)**。
  待办（用户提过）：COT 周报推送通知、TestFlight 上架（免 7 天签名烦恼）、brew install xcodegen。
- GitHub Actions `update.yml`：已加失败日志捕获并升级 action 版本；
  **2026-10-01 根因已定位：`gold_cot.py` 新增 `fetch_sina_quotes()` 时漏了 `import re`，
  导致 `build_ta_data()` 抛 NameError，技术分析页 `ta_data.js` 写不出来，
  所以页面 K线卡在 9/28；已补 `import re`。**
- 待处理（用户新提）：`barchart.com/stocks` 52 周数据页面显示问题（需确认是哪个项目/页面）。
- 待办（用户提过）：COT 周报推送通知、TestFlight 上架（免 7 天签名烦恼）。
