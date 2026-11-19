import SwiftUI
import Combine

// MARK: - 技术分析页 (与网页 dashboard_ta.html 同功能)

struct TAView: View {
    @EnvironmentObject private var store: DataStore
    @State private var period: TaPeriod = .day
    @AppStorage("goldCotZoomStart") private var zoomStart = 0.0
    @AppStorage("goldCotZoomEnd") private var zoomEnd = 1.0
    @State private var shareItem: ShareItem?
    @State private var hiddenMA: Set<String> = []
    @State private var hiddenAISC: Set<String> = []
    @State private var hiddenMACD: Set<String> = []
    @State private var hiddenKDJ: Set<String> = []

    // 重计算结果缓存: 只在数据/周期变化时重算, 拖动滑块时每帧不再重复聚合
    @State private var ohlcAll: [Ohlc] = []
    @State private var domain: ClosedRange<Date> = Date()...Date()

    private func recomputeBase() {
        let agg = Indicators.aggregate(store.ta.ohlc, period: period)
        ohlcAll = agg
        let ds = agg.map(\.date) + store.cot.price.map(\.date)
        if let lo = ds.min(), let hi = ds.max(), hi > lo { domain = lo...hi }
    }

    private var range: ClosedRange<Double> { zoomStart...zoomEnd }

    private var rangeBinding: Binding<ClosedRange<Double>> {
        Binding(get: { range }, set: {
            zoomStart = $0.lowerBound
            zoomEnd = $0.upperBound
        })
    }

    private var window: ClosedRange<Date> { Date().window(range, in: domain) }

    /// 指标先在完整周期序列上计算，再按可视区间取点，避免降采样改变指标值。
    private func indicatorPoints(_ values: [Double?]) -> [(Date, Double)] {
        downsample(zip(ohlcAll, values).compactMap { row, value -> (Date, Double)? in
            guard let value, window.contains(row.date) else { return nil }
            return (row.date, value)
        })
    }

    /// 滑块上方显示的当前选中区间
    private var windowLabel: String {
        "\(DateUtil.short.string(from: window.lowerBound)) ~ \(DateUtil.short.string(from: window.upperBound))"
    }

    /// 当前窗口内的 K 线 (保形降采样)
    private var ohlc: [Ohlc] {
        downsampleOhlc(ohlcAll.filter { window.contains($0.date) }, max: 300)
    }

    private var closes: [Double] { ohlc.map(\.close) }

    var body: some View {
        ScrollView {
            if store.ta.ohlc.isEmpty && store.loading {
                ProgressView("正在加载行情…").padding(.top, 60)
            } else if store.ta.ohlc.isEmpty {
                ContentUnavailableView(
                    "暂无数据", systemImage: "wifi.exclamationmark",
                    description: Text(store.errorMessage ?? ""))
            } else {
                Picker("K线周期", selection: $period) {
                    ForEach(TaPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                candlePanel
                maPanel
                aiscPanel
                macdPanel
                rsiPanel
                kdjPanel
                atrPanel

                RangeSlider(range: rangeBinding, label: windowLabel)
                if let lastRefresh = store.lastRefresh {
                    Text("最近刷新 \(lastRefresh.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("COMEX 黄金技术分析")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("导出 CSV", systemImage: "tablecells") { exportCSV() }
                    Button("导出 PNG", systemImage: "photo") { exportPNG() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(ohlcAll.isEmpty)
                RefreshButton()
                ThemeToggleButton()
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .refreshable { await store.refresh() }
        .onAppear { if ohlcAll.isEmpty { recomputeBase() } }
        .onChange(of: period) { _, _ in recomputeBase() }
        .onChange(of: store.ta.updated) { _, _ in recomputeBase() }
        .onChange(of: store.cot.updated) { _, _ in recomputeBase() }
    }

    // MARK: 图1: K线 + 布林带 + 斐波那契 (Canvas)

    private var candlePanel: some View {
        let boll = Indicators.boll(closes)
        let fibs = Indicators.fibLevels(ohlc)
        return Panel(title: "K线 + 布林带(20,2) + 斐波那契回撤位", height: 320) {
            CandleChartView(ohlc: ohlc, boll: boll, fibs: fibs, xDomain: window)
        }
    }

    // MARK: 图2: 收盘价 + 均线 MA5/10/20/60/100/120/250

    private let maDefs: [(String, Int, Color)] = [
        ("MA5", 5, .red), ("MA10", 10, .orange), ("MA20", 20, .blue),
        ("MA60", 60, .green), ("MA100", 100, .indigo),
        ("MA120", 120, .purple), ("MA250", 250, .secondary),
    ]

    private var maPanel: some View {
        var arr: [CanvasSeries] = []
        if !hiddenMA.contains("收盘价") {
            arr.append(CanvasSeries(name: "收盘价", color: .secondary,
                                    points: ohlc.map { ($0.date, $0.close) }))
        }
        let cl = closes
        for (name, n, color) in maDefs where !hiddenMA.contains(name) {
            guard cl.count >= n else { continue }
            let ma = Indicators.sma(cl, n)
            let pts: [(Date, Double)] = zip(ohlc.map(\.date), ma).compactMap { d, v in
                v.map { (d, $0) }
            }
            arr.append(CanvasSeries(name: name, color: color, points: pts))
        }
        return Panel(title: "收盘价 + 均线 MA", height: 250) {
            VStack(spacing: 4) {
                LegendToggle(items: [("收盘价", Color.secondary)]
                             + maDefs.map { ($0.0, $0.2) },
                             hidden: $hiddenMA)
                MultiLineCanvas(left: arr, height: 208, xDomain: window)
            }
        }
    }

    // MARK: 图3: 金价 vs 行业平均开采成本 (AISC) + 比值 (双轴)

    private var aiscPanel: some View {
        let price = hiddenAISC.contains("金价") ? [] :
            downsample(store.cot.price.filter { window.contains($0.date) })
                .map { ($0.date, $0.value) }
        let costPts: [(Date, Double)] = hiddenAISC.contains("AISC 成本") ? [] :
            store.ta.cost.map {
                var c = DateComponents(); c.year = $0.year; c.month = 1; c.day = 1
                let d = Calendar.current.date(from: c) ?? Date()
                return (d, $0.value)
            }
        let ratioPts: [(Date, Double)] = (hiddenAISC.contains("比值") || store.ta.cost.isEmpty) ? [] :
            downsample(store.cot.price.filter { window.contains($0.date) }).compactMap { p in
                let y = Calendar.current.component(.year, from: p.date)
                guard let cost = store.ta.cost.last(where: { $0.year <= y })?.value,
                      cost > 0 else { return nil }
                return (p.date, p.value / cost)
            }
        return Panel(title: "金价 vs 行业平均开采成本 (AISC) 及 金价/AISC 比值", height: 230) {
            VStack(spacing: 4) {
                LegendToggle(items: [("金价", C.gold), ("AISC 成本", .teal),
                                     ("比值", .brown)],
                             hidden: $hiddenAISC)
                MultiLineCanvas(
                    left: [
                        CanvasSeries(name: "金价", color: C.gold, points: price),
                        CanvasSeries(name: "AISC", color: .teal, dashed: true,
                                     points: costPts),
                    ],
                    right: [CanvasSeries(name: "比值", color: .brown, points: ratioPts)],
                    height: 198, xDomain: window)
            }
        }
    }

    // MARK: 图4: MACD(12,26,9) + 金叉/死叉标注

    private var macdPanel: some View {
        let m = Indicators.macd(closes)
        let dates = ohlc.map(\.date)
        let crosses: [(Date, Double, String)] = hiddenMACD.contains("金叉/死叉") ? [] :
            m.crosses.compactMap { c in
                guard c.index < dates.count else { return nil }
                return (dates[c.index], m.dif[c.index], c.kind == 1 ? "金叉" : "死叉")
            }
        return Panel(title: "MACD(12, 26, 9) — 金叉 / 死叉", height: 230) {
            VStack(spacing: 4) {
                LegendToggle(items: [("DIF", .red), ("DEA", .blue),
                                     ("MACD 柱", C.mm), ("金叉/死叉", .purple)],
                             hidden: $hiddenMACD)
                MacdCanvas(dates: dates, hist: m.hist, dif: m.dif, dea: m.dea,
                           crosses: crosses, hidden: hiddenMACD, height: 198,
                           xDomain: window)
            }
        }
    }

    // MARK: 图5: RSI(14)

    private var rsiPanel: some View {
        let points = indicatorPoints(Indicators.rsi(ohlcAll.map(\.close)))
        return Panel(title: "RSI(14) — 相对强弱指数", height: 170) {
            MultiLineCanvas(
                left: [CanvasSeries(name: "RSI14", color: .purple, points: points)],
                hLines: [(70, "超买 70"), (30, "超卖 30"), (50, "50")],
                height: 138, xDomain: window, yDomain: 0...100)
        }
    }

    // MARK: 图6: KDJ(9,3,3)

    private var kdjPanel: some View {
        let values = Indicators.kdj(ohlcAll)
        let definitions = [("K", values.k, Color.blue),
                           ("D", values.d, Color.orange),
                           ("J", values.j, Color.red)]
        let lines = definitions.filter { !hiddenKDJ.contains($0.0) }.map {
            CanvasSeries(name: $0.0, color: $0.2, points: indicatorPoints($0.1))
        }
        return Panel(title: "KDJ(9, 3, 3) — 随机指标", height: 200) {
            VStack(spacing: 4) {
                LegendToggle(items: [("K", .blue), ("D", .orange), ("J", .red)],
                             hidden: $hiddenKDJ)
                MultiLineCanvas(left: lines, hLines: [(80, "80"), (20, "20")],
                                height: 158, xDomain: window)
            }
        }
    }

    // MARK: 图7: ATR(14)

    private var atrPanel: some View {
        let points = indicatorPoints(Indicators.atr(ohlcAll))
        return Panel(title: "ATR(14) — 平均真实波幅", height: 170) {
            MultiLineCanvas(
                left: [CanvasSeries(name: "ATR14", color: C.dxy, points: points)],
                height: 138, xDomain: window)
        }
    }

    // MARK: 导出当前可视区间

    private func exportCSV() {
        let rsi = Indicators.rsi(ohlcAll.map(\.close))
        let kdj = Indicators.kdj(ohlcAll)
        let atr = Indicators.atr(ohlcAll)
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? ""
        }
        var lines = ["日期,开盘,收盘,最高,最低,RSI14,K,D,J,ATR14"]
        for (i, row) in ohlcAll.enumerated() where window.contains(row.date) {
            let fields = [DateUtil.short.string(from: row.date), "\(row.open)", "\(row.close)",
                          "\(row.high)", "\(row.low)", number(rsi[i]), number(kdj.k[i]),
                          number(kdj.d[i]), number(kdj.j[i]), number(atr[i])]
            lines.append(fields.joined(separator: ","))
        }
        guard lines.count > 1 else { return }
        let name = "gold_ta_\(DateUtil.short.string(from: ohlcAll[0].date))_\(period.rawValue).csv"
        shareItem = AppExport.csv(lines: lines, name: name).map { ShareItem(url: $0) }
    }

    private func exportPNG() {
        let content = VStack(alignment: .leading, spacing: 0) {
            Text("COMEX 黄金技术分析 · \(windowLabel)")
                .font(.headline).padding()
            candlePanel
            maPanel
            aiscPanel
            macdPanel
            rsiPanel
            kdjPanel
            atrPanel
        }
        .frame(width: 900)
        shareItem = AppExport.png(of: content, name: "gold_ta_dashboard.png").map { ShareItem(url: $0) }
    }
}


// MARK: - 实时行情页 (与网页 realtime.html 同功能)
// 三品种卡片(点按切换) + 日K + MACD; 每 10 秒直连东方财富刷新报价,
// 历史K线来自 rt_charts.js 主数据, 当前 bar 用实时报价合成更新。

struct RealtimeView: View {
    @EnvironmentObject private var store: DataStore
    @State private var selected = "gc"
    @State private var hiddenMACD: Set<String> = []

    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private let names: [String: String] = ["xau": "伦敦金 XAU/USD",
                                           "gc": "COMEX 黄金 GC",
                                           "sge": "上海黄金 T+D"]

    // MARK: 数据装配: 历史(最近180根) + 实时合成当日 bar

    private var history: [Ohlc] {
        Array((store.rtCharts[selected] ?? []).suffix(180))
    }

    private var quote: RtQuote? { store.quotes.first { $0.key == selected } }

    private var ohlc: [Ohlc] {
        var rows = history
        guard let q = quote, let last = q.last else { return rows }
        let today = DateUtil.parse(DateUtil.short.string(from: Date())) ?? Date()
        if let base = rows.last, Calendar.current.isDate(base.date, inSameDayAs: today) {
            // 历史已含今日(未收盘)bar: 收盘价刷新 + 高低扩展
            rows[rows.count - 1] = Ohlc(date: today, open: base.open, close: last,
                                        high: max(base.high, last), low: min(base.low, last))
        } else {
            // 历史不含今日: 用昨收为开盘合成当日实时 bar
            let prev = rows.last
            rows.append(Ohlc(date: today, open: prev?.close ?? last, close: last,
                             high: max(prev?.close ?? last, last),
                             low: min(prev?.close ?? last, last)))
        }
        return rows
    }

    private var closes: [Double] { ohlc.map(\.close) }

    // MARK: 子视图

    private var cards: some View {
        HStack(spacing: 10) {
            ForEach(store.quotes) { q in
                Button {
                    selected = q.key
                }                 label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(names[q.key] ?? q.name).font(.caption2)
                                .foregroundStyle(.secondary)
                            if q.stale {
                                Text("休市").font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(q.last != nil ? String(format: "%.2f", q.last!) : "--")
                                .font(.headline).monospacedDigit()
                            if let c = q.change, let p = q.changePct {
                                Text(String(format: "%+.2f(%+.2f%%)", c, p))
                                    .font(.caption2)
                                    .foregroundStyle(c >= 0 ? .red : .green)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selected == q.key ? Color.orange : Color.clear,
                                    lineWidth: 2)
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private var candlePanel: some View {
        let rows = ohlc
        return Panel(title: "\(names[selected] ?? "") 日K", height: 320) {
            CandleChartView(ohlc: rows, boll: Indicators.boll(closes),
                            fibs: Indicators.fibLevels(rows), xDomain: nil)
        }
    }

    private var macdPanel: some View {
        let m = Indicators.macd(closes)
        let dates = ohlc.map(\.date)
        return Panel(title: "MACD(12, 26, 9)", height: 200) {
            VStack(spacing: 4) {
                LegendToggle(items: [("DIF", .red), ("DEA", .blue), ("MACD 柱", C.mm)],
                             hidden: $hiddenMACD)
                MacdCanvas(dates: dates, hist: m.hist, dif: m.dif, dea: m.dea,
                           crosses: [], hidden: hiddenMACD, height: 168,
                           xDomain: nil)
            }
        }
    }

    var body: some View {
        ScrollView {
            if store.rtCharts.isEmpty && store.loading {
                ProgressView("正在加载行情…").padding(.top, 60)
            } else {
                cards
                candlePanel
                macdPanel
                Text("每 10 秒自动刷新实时报价 · 更新于 \(store.quotes.first?.time ?? "--")")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .navigationTitle("实时行情")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                RefreshButton()
                ThemeToggleButton()
            }
        }
        .refreshable { await store.refresh() }
        .onReceive(timer) { _ in
            Task { await store.refreshRtQuotesLive() }
        }
        .onAppear {
            Task { await store.refreshRtQuotesLive() }
        }
    }
}
