# 黄金 COT 看板 iOS App

原生 SwiftUI App，数据直接来自本网站已发布的端点（与网页版完全同源、同口径）。

## 功能（与网页版一致）

- **持仓看板**：最新报告卡片、时间维度切换（周/月/季/年）、管理基金净持仓 vs 金价（双轴）、五类交易者对比、多空分项、总持仓、金价 vs 美元指数、黄金期权 PCR（沪金双口径 + 美国 GLD）
- **技术分析**：日K/周K/月K 切换、K线 + 布林带(20,2) + 斐波那契回撤位、MA5/10/20/60/120/250、金价 vs 开采成本 AISC 及比值、MACD(12,26,9) + 金叉/死叉标注

## 环境要求

- macOS + Xcode 15+（iOS 17 SDK）
- [XcodeGen](https://github.com/yonsm/XcodeGen)（用它从 `project.yml` 生成工程）

## 构建运行（3 步）

```bash
# 1. 安装 XcodeGen（只需一次）
brew install xcodegen

# 2. 生成 Xcode 工程
cd app
xcodegen

# 3. 打开工程运行
open GoldCotTracker.xcodeproj
```

在 Xcode 里选择目标 **GoldCotTracker** → 运行目标选 **iPhone 模拟器**（直接 ⌘R），
或选自己的 iPhone（用免费 Apple ID 登录 Xcode → Signing & Capabilities →
勾选 Automatically manage signing，即可真机运行，7 天重签一次）。

## 发布成可下载的 IPA（可选）

需要 Apple Developer 账号（$99/年）才能签名分发给他人；
免费账号只能安装到自己的设备。有付费账号时：

```bash
# 通用链接方式打包（在 app/ 目录下，工程生成后）
xcodebuild -scheme GoldCotTracker -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build
# 再到 Xcode → Product → Archive → Distribute App 导出 IPA
```

## 数据源

App 启动时从本仓库发布的静态 JSON 拉取（无需自建服务器）：

- `data/cot_data.json` — COT 持仓 + 金价 + 美元指数 + PCR
- `data/ta_data.js` — 技术分析行情（OHLC + 开采成本）

由 GitHub Actions 每小时自动更新，App 端下拉即可刷新。
