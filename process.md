# Process — 项目接续工作手册

> 本文件在**每次任务时更新**，配合 README.md，保证任何一次会话中断后，下一个会话（人或 AI）能
> 零成本接续。最后更新：2026-11-20（会话：iOS 实时行情时间轴缩放、持仓背离标注防重叠与真机更新）。

## 一句话项目

抓取 CFTC 黄金 COT 持仓 + 金价/美元指数/期权 PCR，产出：
① 网页看板 `dashboard.html`、② 网页技术分析页 `dashboard_ta.html`、③ 实时行情页 `realtime.html`
（GitHub Pages 线上自动更新）、④ iOS App `GoldCotTracker`（SwiftUI，已装用户真机）。

## 仓库结构

```
gold_cot.py              # 唯一数据流水线: 抓取→缓存→生成网页与数据文件
dashboard_template.html  # 看板模板（改网页必须改模板，再用数据注入生成 dashboard.html）
dashboard_ta_template.html # 技术分析页模板（同理生成 dashboard_ta.html）
dashboard.html / dashboard_ta.html  # 生成产物（含注入数据，与模板同步修改）
realtime.html            # 实时行情页（三品种快照 + 日K + MACD，独立维护）
echarts.min.js           # 本地内置 ECharts 5.5（勿改回 CDN，用户网络访问 jsdelivr 不稳定）
data/                    # cot_data.json / ta_data.js / ta_ohlc.json / 各类缓存（Actions 定时提交）
app/                     # iOS App 全部源码 + Xcode 工程
  Sources/               # GoldCotTrackerApp.swift(三Tab/主题/分享) / DashboardView / TAView /
                         # ChartViews.swift(Panel/RangeSlider/LegendToggle/MultiLineCanvas/MacdCanvas/YAxisLabels/ChartTooltip)
                         # CandleChartView / Indicators.swift(指标计算) / DataStore.swift(联网刷新, 无磁盘数据缓存)
  Sources/Assets.xcassets # AppIcon + AccentColor；AppIcon 源图由 app/generate_icon.py 生成
  project.yml            # XcodeGen 配置源；无 XcodeGen 时需同步手工维护 pbxproj 并留痕
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
  **裸 HTTP 请求必须带 User-Agent, 否则东财直接掐断连接(2026-10-01 App 踩过: "网络连接已中断")**。
  **rt_charts.js 必须保留全量历史**(write_rt_charts 的 weeks 不能截断, 曾误用 52 周):
  App TA 页时间域 = K线日期 ∪ cot.price 日期, K线只有 1 年而价格线 10 年时, 图表会挤在最右侧 10%。
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
# 构建前检查（完整 JSON 留痕；路径按当前插件安装位置调整）
MOBILE_SKILLS="$HOME/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/plugins/managed/mobile-app-building/skills"
python3 "$MOBILE_SKILLS/mobile-app-preview/scripts/check_environment.py" \
  ios --purpose build --project "$PWD/app" --json

# 模拟器构建（快迭代用这个验证 UI）
xcodebuild -project app/GoldCotTracker.xcodeproj -scheme GoldCotTracker \
  -configuration Debug -sdk iphonesimulator build \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES
# 使用技能助手安装、启动、截图；必须绑定明确 UDID 和工程归属
python3 "$MOBILE_SKILLS/ios-app-building/scripts/simulator.py" \
  --app "$HOME/Library/Developer/Xcode/DerivedData/GoldCotTracker-frugtszushkfjaabdqeolmrvhdvv/Build/Products/Debug-iphonesimulator/GoldCotTracker.app" \
  --udid FE323DBE-E1BE-477C-A82E-559B79DC65D9 --run \
  --screenshot "$PWD/artifacts/ios-current.png" --preview-owner "$PWD/app"

# 真机构建：当前环境用 generic/platform=iOS；实体设备 destination 曾无法识别
xcodebuild -project app/GoldCotTracker.xcodeproj -scheme GoldCotTracker \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=MQM879TDKM \
  CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES build
xcrun devicectl device install app --device 00008150-001129390E62401C \
  "$HOME/Library/Developer/Xcode/DerivedData/GoldCotTracker-frugtszushkfjaabdqeolmrvhdvv/Build/Products/Debug-iphoneos/GoldCotTracker.app"
xcrun devicectl device process launch --device 00008150-001129390E62401C \
  --terminate-existing com.tsingshuizhang.GoldCotTracker
```

- **签名团队**：`MQM879TDKM`（Apple ID tsingshui@hotmail.com，个人免费账号）。
  注意证书 CN 括号里的 M4342XHZX7 是证书用户 ID，不是团队 ID；OU 字段才是团队 ID。
- **免费账号 7 天过期**：真机 App 到期打不开，重新构建安装即可（手机上已信任过证书不用重设）。
- 用户真机：iPhone 17 Pro Max，UDID `00008150-001129390E62401C`。
- 模拟器被现有预览占用时，不要停止其他任务或绕过归属保护；核对同一工程 owner，
  保留可用预览，并如实记录新版模拟器安装/视觉验证是否完成。
- **2026-09-28 与 2026-11-20 真机安装遇 `com.apple.dt.CoreDeviceError 4016`**：
  `The device is not able to fulfill the requested usage assertion requirements.`
  通常是手机**锁屏/熄屏/忙**导致；解锁并保持亮屏后重试。2026-11-20 用户确认解锁后安装成功。

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
  只在数据/周期变化时重算，拖动每帧零重算。这是内存计算缓存，不是网络磁盘缓存。
- TA 页 **7 图**共享显式 X 轴（xDomain=window）；看板 6 图各用自身数据范围（PCR 数据 2022 年才有，
  共享全局限会挤压成竖线——这个坑已踩过）。
- **Indicators 有边界保护**：boll/macd 数据不足 n 条时返回空（`19..<5` 非法区间崩溃事故过）；
  2026-11-20 新增 RSI(14)、KDJ(9,3,3)、ATR(14)。
- 外观：三页共用 `@AppStorage("goldCotTheme")`，值为 `auto|light|dark`，默认跟随系统；
  图表和文字继续使用系统自适应色，禁止写死影响深色对比度的颜色。
- `DataStore.refresh()` 已改为直接联网取最新数据，**不再读写磁盘数据缓存**；
  请求加时间戳和 `no-cache`，并避免并发重复刷新。启动、回前台、下拉和刷新按钮均可触发更新。
- 持仓/技术页通过 `AppExport` + 系统分享面板导出 CSV/PNG；导出使用当前可视区间。
- **签名已配置为自动** (2026-10-01 起): pbxproj + project.yml 里
  `CODE_SIGNING_ALLOWED=YES / CODE_SIGN_STYLE=Automatic / DEVELOPMENT_TEAM=MQM879TDKM`。
- **图标与资产**：`Sources/Assets.xcassets/AppIcon.appiconset` 是 1024×1024 无透明通道源图，
  `project.yml` 设置 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`。本机无可用 `xcodegen`，
  本次已把 Assets 引用、Resources Build Phase、Debug/Release AppIcon 设置手工同步到 pbxproj；
  将来重新生成工程时必须确认这些设置仍在，不能只改其中一个工程文件。

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

## 文档同步与接力规则（强制）

1. **每次修改后都更新文档**：代码、模板、数据逻辑或页面布局修改后，必须在同一提交中更新本文件；用户可见功能、命令、数据源或输出文件变化时，同时更新 `README.md`。
2. 每次台账至少写清：修改日期与目的、涉及文件、验证命令与结果、遗留问题、对应提交号。自动数据提交可简记，功能性提交不得只写“已完成”。
3. 严格区分**本地生成/浏览器验证**与**GitHub Pages 线上复核**；未实际检查的线上页面、接口或数据日期不得写成“正常”或“已更新”。
4. 网页改动必须同步模板与生成页；数据抓取失败、使用既有缓存、验证范围受限等情况必须明确记录，供下一位 Agent 接续。

## 提交前检查清单

- [ ] 网页 4 文件（2 模板 + 2 生成页）同步修改，node --check 通过；实时页改动单独检查
- [ ] App 模拟器构建通过、截图确认图表区/图例/滑块渲染正常
- [ ] 改了数据逻辑 → 确认 Actions workflow 的 cron/命令不需要同步调整
- [ ] **文档已同步**：按上方规则更新本文件，必要时更新 README.md，并记录验证边界
- [ ] push 带重试循环，确认 `main -> main` 再收工

## 当前状态（2026-11-20 更新）

### 今日修改台账

| 提交 | 修改内容 | 主要涉及文件 |
|---|---|---|
| `208e19f` | 完成 7 项功能：COT 1/3/5 年净持仓分位数、RSI/KDJ/ATR、COT 与金价背离、跨页时间区间联动、PNG/CSV 导出、深色模式、Bark/Telegram 周报推送 | `gold_cot.py`、`dashboard_template.html`、`dashboard_ta_template.html`、两份生成页、`.github/workflows/update.yml`、`run.sh`、相关数据文件 |
| `54e5ffa` | 用更新后的流水线重新生成持仓看板及行情数据 | `dashboard.html`、`data/cot_data.json`、`data/dxy_daily.json`、`data/rt_charts.js`、`data/rt_quotes.js`、`data/ta_data.js`、`data/ta_ohlc.json` |
| `b5de8b7` | 三页补齐深色/浅色手动切换，修复深色下正文、辅助文字和图表配色对比度；主题以 `goldCotTheme=auto|dark|light` 跨页保存 | `dashboard_template.html`、`dashboard_ta_template.html`、两份生成页、`realtime.html`、相关数据文件 |
| `4dd8882` | 技术分析页 K 线周期控制区独占一行；主题按钮移出导航组并放到右侧状态区之后 | `dashboard_ta_template.html`、`dashboard_ta.html`、相关行情数据文件 |
| `cc3f246` | 持仓页主题按钮移出导航组，通过 `.header > .theme-btn { margin-left:auto }` 固定在顶行最右侧，顶行布局与其他页面统一 | `dashboard_template.html`、`dashboard.html`、相关数据文件 |
| `965fb1e` | 原生 App 同步三页主题/刷新、分位数与背离、RSI/KDJ/ATR、CSV/PNG 导出；新增主屏幕图标并同步工程配置 | `app/Sources/`、`app/Sources/Assets.xcassets/`、`app/project.yml`、pbxproj、`README.md`、`process.md` |

主题实现注意：`applyTheme(..., false)` 首次只初始化不重绘，避免在 `CHART_COLORS` 或 `chart` 初始化前触发 TDZ/空对象错误；模板修改后必须重新生成对应 HTML。

### 本地生成与验证（2026-11-18）

- 持仓页：**6 个面板、17 个序列**；技术分析页：**7 个面板、23 个序列**；实时行情页：**9 个序列**。
- 三页深色/浅色切换均已做本地浏览器验证；本次捕获的 **23 个请求均返回 HTTP 200**。
- 本地生成数据：COT 最新报告 **2026-11-10**，共 **528 期**；沪金期权 PCR 共 **646 条**。
- 本次仅同步文档，不重新生成 HTML，也不把上述本地结果当作线上复核结果。

### 数据源与线上状态

- 数据生成时观察到东方财富连接中断，以及 Yahoo **403 / SSL EOF**；页面使用既有缓存。上述异常仍需后续排查，不能据此声称在线数据源已恢复或实时数据已核验。
- GitHub Pages 三页（持仓看板 / 技术分析 / 实时行情）**本轮未复核**；旧台账中的线上“正常”及 2026-10 月数据日期不再作为当前状态引用。线上以 Actions 实际提交和页面复核为准。

### App 功能与图标修复（2026-11-20）

- **目的**：把网页版近期功能同步到原生 App，修复手机仍显示旧数据、缺少深浅色切换和主屏幕图标异常。
- **源码修改**：`GoldCotTrackerApp.swift` 增加三页主题菜单、刷新、回前台刷新及分享基础设施；
  `DataStore.swift` 禁用磁盘数据缓存、请求加时间戳并合并并发刷新；`Indicators.swift` 增加 RSI/KDJ/ATR；
  `ChartViews.swift` 增加参考线、信号点和固定 Y 轴；`DashboardView.swift` 增加分位数、COT 背离、区间联动及导出；
  `TAView.swift` 扩为 7 面板并增加导出，实时页同步主题和刷新。
- **图标修复**：原工程无 `Assets.xcassets`，旧包也没有 `CFBundleIcons`。新增 `generate_icon.py`、
  1024×1024 无透明通道的 `AppIcon-1024.png`、AppIcon/AccentColor 资产目录；`project.yml` 和 pbxproj 均已同步。
  `actool` 实际生成 `AppIcon60x60@2x.png`、`AppIcon76x76@2x~ipad.png` 和 `Assets.car`，
  新包 `Info.plist` 含 `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName=AppIcon`。

### App 构建、安装与验证边界（2026-11-20）

- 环境检查 `check_environment.py ios --purpose build --json` 返回 `status=pass`，macOS/Xcode 为 ready。
- **模拟器**：含图标的 Debug-iphonesimulator 构建已成功（`build-simulator-current.log`）。
  图标加入前的持仓页浅色、系统深色画面已截图并人工查看，分位数卡片和主要图表显示正常。
  但本轮用技能助手安装新版时，两次均因 UDID `FE323DBE-E1BE-477C-A82E-559B79DC65D9`
  已被现有预览占用而在安装前停止；未停止该预览，也未绕过归属保护。因此**新版模拟器安装、
  主屏幕图标视觉和新增页面交互均未验收**，现有浏览器预览不能当作新版证据。
- **真机**：含图标的 Debug-iphoneos 构建成功，完整日志为 `artifacts/build-device-icon.log`。
  `inspect_app.py` 确认 Bundle ID `com.tsingshuizhang.GoldCotTracker`、版本 **1.0 (1)**、最低 iOS 17.0、
  arm64 iPhoneOS 产物；`codesign --verify --deep --strict` 通过。描述文件团队为 `MQM879TDKM`，
  包含 UDID `00008150-001129390E62401C`，原始 `ExpirationDate` 为 **2026-11-26 17:20:12 UTC**。
- 用户确认手机已解锁后，`devicectl device install app` 于本轮返回 **App installed**；
  随后 `devicectl device process launch --terminate-existing` 返回启动成功。这证明安装和进程启动，
  **不等于**真机画面、主屏幕图标视觉或触控功能已验收。
- 早前浏览器 WebMCP 与原生 UI 自动化对技术分析/主题控件的点按只返回已分发或成功，但画面未变化；
  已停止重复尝试。技术分析 7 面板、实时页按钮、手动主题菜单、CSV/PNG 导出均仍需真实交互验收。
- 本地截图和构建日志仅作验证留痕，不纳入版本库。真机安装使用 DerivedData 下的 `.app`，不是 IPA，
  也不是可分发的 App Store/TestFlight 包。
- 待办：在手机上人工确认主屏幕图标、三页主题/刷新和导出；处理模拟器预览归属后再验收新版；
  复核 GitHub Pages 三页及 Actions 最新运行；排查东方财富/Yahoo 抓取异常；考虑 TestFlight 避免 7 天签名限制。
- 待确认：`barchart.com/stocks` 52 周数据页面显示问题（用户提过，需确认具体页面）。

### App 实时缩放与背离标注防叠字（2026-11-20）

- **目的**：实时行情页按时间轴缩放；修复手机持仓看板在周/月/季/年切换后，零轴附近
  “顶背离 / 底背离”等文字堆叠的问题。
- **源码修改**：`TAView.swift` 的 `RealtimeView` 新增规范化 `range`、共享时间域 `window`
  和可视 OHLC；K 线与 MACD 使用同一时间窗口，底部 `RangeSlider` 支持拖动两端缩放、
  双击复位，切换品种保留规范化区间。`ChartViews.swift` 保留全部可见信号圆点，
  文字仅从最近 4 个候选中选显，要求至少 44 px 水平间距，并将顶背离/底背离分别置于
  信号点上方/下方；文字位置同时限制在绘图区内。
- **对应提交**：功能与说明文档为 `ead1320`（`fix: improve iOS chart zoom and marker layout`）；
  本验证台账的提交号回填见随后 docs 提交。
- **构建**：环境检查 `ios --purpose build --json` 返回 `status=pass`，macOS 与 Xcode 27.2 ready。
  实时缩放的模拟器/真机构建分别见 `artifacts/build-simulator-realtime-zoom.log`、
  `artifacts/build-device-realtime-zoom.log`；加入标注布局后的模拟器/真机构建分别见
  `artifacts/build-simulator-marker-layout.log`、`artifacts/build-device-marker-layout.log`。
  四次构建均以 `** BUILD SUCCEEDED **` 结束。
- **模拟器**：新版通过技能助手安装并启动到 `B37F7564-27C6-49CA-9F77-674BE2AD2F6D`，
  Bundle ID `com.tsingshuizhang.GoldCotTracker`，版本 1.0 (1)。已实际查看
  `artifacts/ios-marker-layout.png`：默认“周”页面正常，管理基金净持仓图信号点保留，
  右侧仅见一个置于零轴下方的“底背离”文字，未见此前多处文字堆叠。此项只是当前画面证据，
  不能外推为所有周期均已通过真实切换验收。
- **交互限制**：原生 UI 自动化点按“月”虽返回成功，但随后的 UI 快照中“周”仍为 1、“月”仍为 0，
  画面未证明发生切换，已停止重复该路径。浏览器预览标签页存在，但截图和 WebMCP 状态均返回
  `IN_APP_BROWSER_TAB_NOT_VISIBLE`，因此未通过浏览器执行触摸。实时页滑块视觉、拖动手势及
  周/月/季/年实际切换仍未自动验收；代码连线与构建结果不能替代手势验证。
- **真机**：最终版 `codesign --verify --deep --strict` 通过；`devicectl` 已将同一真机包安装到
  `00008150-001129390E62401C` 并以 `--terminate-existing` 成功启动，完整输出见
  `artifacts/device-install-marker-layout.log`。这仅证明签名、安装和进程启动，真机画面、
  周期切换和实时缩放手势仍需用户人工确认。
- 本批截图、安装输出和构建日志仅本地留痕，不纳入版本库；未重新复核 GitHub Pages。
