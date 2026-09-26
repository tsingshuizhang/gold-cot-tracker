import SwiftUI

// MARK: - 技术分析页 (与网页 dashboard_ta.html 同功能)

struct TAView: View {
    @EnvironmentObject private var store: DataStore
    @State private var period: TaPeriod = .day
    @State private var range: ClosedRange<Double> = 0...1
    @State private var hiddenMA: Set<String> = []
    @State private var hiddenAISC: Set<String> = []
    @State private var hiddenMACD: Set<String> = []

    // 重计算结果缓存: 只在数据/周期变化时重算, 拖动滑块时每帧不再重复聚合
    @State private var ohlcAll: [Ohlc] = []
    @State private var domain: ClosedRange<Date> = Date()...Date()

    private func recomputeBase() {
        let agg = Indicators.aggregate(store.ta.ohlc, period: period)
        ohlcAll = agg
        let ds = agg.map(\.date) + store.cot.price.map(\.date)
        if let lo = ds.min(), let hi = ds.max(), hi > lo { domain = lo...hi }
    }

    private var window: ClosedRange<Date> { Date().window(range, in: domain) }

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

                RangeSlider(range: $range)
            }
        }
        .navigationTitle("COMEX 黄金技术分析")
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

    // MARK: 图2: 收盘价 + 均线 MA5/10/20/60/120/250

    private let maDefs: [(String, Int, Color)] = [
        ("MA5", 5, .red), ("MA10", 10, .orange), ("MA20", 20, .blue),
        ("MA60", 60, .green), ("MA120", 120, .purple), ("MA250", 250, .gray),
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
}
