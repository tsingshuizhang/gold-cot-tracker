import SwiftUI

// MARK: - 持仓看板页 (与网页 dashboard.html 同功能)

struct DashboardView: View {
    @EnvironmentObject private var store: DataStore
    @State private var dim: Dim = .week
    @State private var range: ClosedRange<Double> = 0...1
    @State private var hiddenNet: Set<String> = []
    @State private var hiddenCat: Set<String> = []
    @State private var hiddenLS: Set<String> = []
    @State private var hiddenPD: Set<String> = []
    @State private var hiddenPCR: Set<String> = []

    // 重计算结果缓存: 只在数据/维度变化时重算, 拖动滑块每帧不再重复排序+遍历上万日期
    @State private var seriesCache: [CotRecord] = []
    @State private var domainCache: ClosedRange<Date> = Date()...Date()

    var series: [CotRecord] { seriesCache }

    /// 全页统一时间域 (所有序列日期最小~最大)
    private var domain: ClosedRange<Date> { domainCache }

    private func recomputeBase() {
        let s = store.cotSeries(dim: dim)
        seriesCache = s
        var lo = Date.distantFuture, hi = Date.distantPast
        for d in s.map(\.date) + store.cot.price.map(\.date)
                + store.cot.dxy.map(\.date)
                + store.cot.pcr.shfe.map(\.date)
                + store.cot.pcr.gld.map(\.date) {
            lo = min(lo, d); hi = max(hi, d)
        }
        if hi > lo { domainCache = lo...hi }
    }

    private var window: ClosedRange<Date> { Date().window(range, in: domain) }

    /// 滑块上方显示的当前选中区间
    private var windowLabel: String {
        "\(DateUtil.short.string(from: window.lowerBound)) ~ \(DateUtil.short.string(from: window.upperBound))"
    }

    var body: some View {
        ScrollView {
            if store.cot.cot.isEmpty && store.loading {
                ProgressView("正在加载数据…").padding(.top, 60)
            } else if store.cot.cot.isEmpty {
                ContentUnavailableView(
                    "暂无数据",
                    systemImage: "wifi.exclamationmark",
                    description: Text(store.errorMessage ?? "")
                )
            } else {
                cards
                Picker("时间维度", selection: $dim) {
                    ForEach(Dim.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                netPanel
                categoryPanel
                longShortPanel
                oiPanel
                priceDxyPanel
                pcrPanel

                RangeSlider(range: $range, label: windowLabel)
            }
        }
        .navigationTitle("黄金 CFTC COT 持仓看板")
        .refreshable { await store.refresh() }
        .onAppear { if seriesCache.isEmpty { recomputeBase() } }
        .onChange(of: dim) { _, _ in recomputeBase() }
        .onChange(of: store.cot.updated) { _, _ in recomputeBase() }
    }

    // MARK: 顶部指标卡片

    private var cards: some View {
        let rows: [(String, String, Double?)] = {
            let s = store.cot.cot.sorted { $0.date < $1.date }
            guard let last = s.last, let prev = s.dropLast().last else { return [] }
            return [
                ("最新报告", DateUtil.short.string(from: last.date), nil),
                ("管理基金净持仓", fmt(last.net), last.net - prev.net),
                ("散户/非报告净持仓", fmt(last.nr), last.nr - prev.nr),
                ("净多占总持仓", String(format: "%.1f%%", last.oi != 0 ? last.net / last.oi * 100 : 0), nil),
                ("总持仓 Open Interest", fmt(last.oi), last.oi - prev.oi),
            ]
        }()
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(rows, id: \.0) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.0).font(.caption).foregroundStyle(.secondary)
                    Text(r.1).font(.title3).bold()
                    if let d = r.2 {
                        Text("\(d >= 0 ? "+" : "")\(fmt(d)) 周环比")
                            .font(.caption2)
                            .foregroundStyle(d >= 0 ? .red : .green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white)
                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: 图1: 管理基金净持仓 vs 金价 (柱 + 右轴线, Canvas)

    private var netPanel: some View {
        let bars = downsample(series.filter { window.contains($0.date) })
            .map { ($0.date, $0.net) }
        let price = downsample(store.cot.price.filter { window.contains($0.date) })
            .map { ($0.date, $0.value) }
        return Panel(title: "管理基金(机构大资金)净持仓 vs 金价", height: 200) {
            VStack(spacing: 4) {
                LegendToggle(items: [("净持仓", C.mm), ("金价", C.gold)],
                             hidden: $hiddenNet)
                MultiLineCanvas(
                    right: hiddenNet.contains("金价") ? [] :
                        [CanvasSeries(name: "金价", color: C.gold, points: price)],
                    bars: hiddenNet.contains("净持仓") ? [] : bars,
                    barName: "净持仓",
                    height: 168)
            }
        }
    }

    // MARK: 图2: 各类交易者净持仓对比

    private let catDefs: [(String, Color)] = [
        ("管理基金(机构)", C.mm), ("生产商/贸易商(套保)", C.pm),
        ("掉期交易商", C.swap), ("其他报告(中小投机)", C.oth),
        ("散户/非报告", C.nr),
    ]

    private var categoryPanel: some View {
        let recs = downsample(series.filter { window.contains($0.date) })
        let keypaths: [(String, KeyPath<CotRecord, Double>, Color)] = [
            ("管理基金(机构)", \.net, C.mm), ("生产商/贸易商(套保)", \.pm, C.pm),
            ("掉期交易商", \.swap, C.swap), ("其他报告(中小投机)", \.oth, C.oth),
            ("散户/非报告", \.nr, C.nr),
        ]
        let seriesArr: [CanvasSeries] = keypaths
            .filter { !hiddenCat.contains($0.0) }
            .map { name, kp, color in
                CanvasSeries(name: name, color: color,
                             points: recs.map { ($0.date, $0[keyPath: kp]) })
            }
        return Panel(title: "各类交易者净持仓对比", height: 200) {
            VStack(spacing: 4) {
                LegendToggle(items: catDefs, hidden: $hiddenCat)
                MultiLineCanvas(left: seriesArr, height: 158)
            }
        }
    }

    // MARK: 图3: 管理基金多空分项

    private var longShortPanel: some View {
        let recs = downsample(series.filter { window.contains($0.date) })
        let arr: [CanvasSeries] = [
            ("多头", \CotRecord.lo, C.mm), ("空头", \CotRecord.sh, C.pm),
        ].filter { !hiddenLS.contains($0.0) }
            .map { name, kp, color in
                CanvasSeries(name: name, color: color,
                             points: recs.map { ($0.date, $0[keyPath: kp]) })
            }
        return Panel(title: "管理基金多空分项", height: 200) {
            VStack(spacing: 4) {
                LegendToggle(items: [("多头", C.mm), ("空头", C.pm)], hidden: $hiddenLS)
                MultiLineCanvas(left: arr, height: 158)
            }
        }
    }

    // MARK: 图4: 总持仓 OI

    private var oiPanel: some View {
        let recs = downsample(series.filter { window.contains($0.date) })
        return Panel(title: "总持仓 Open Interest", height: 130) {
            MultiLineCanvas(
                left: [CanvasSeries(name: "OI", color: C.swap,
                                    points: recs.map { ($0.date, $0.oi) })],
                fillFirst: true, height: 128)
        }
    }

    // MARK: 图5: 金价 vs 美元指数 DXY (双轴)

    private var priceDxyPanel: some View {
        let price = downsample(store.cot.price.filter { window.contains($0.date) })
            .map { ($0.date, $0.value) }
        let dxy = downsample(store.cot.dxy.filter { window.contains($0.date) })
            .map { ($0.date, $0.value) }
        return Panel(title: "金价 vs 美元指数 DXY", height: 220) {
            VStack(spacing: 4) {
                LegendToggle(items: [("金价", C.gold), ("美元指数", C.dxy)],
                             hidden: $hiddenPD)
                MultiLineCanvas(
                    left: hiddenPD.contains("金价") ? [] :
                        [CanvasSeries(name: "金价", color: C.gold, points: price)],
                    right: hiddenPD.contains("美元指数") ? [] :
                        [CanvasSeries(name: "美元指数", color: C.dxy, points: dxy)],
                    height: 188)
            }
        }
    }

    // MARK: 图6: 黄金期权 PCR

    /// ±1σ 滚动标准差轨道 (与网页同口径): 窗口60点, 不足20点不出轨
    private func pcrStdBands(_ pair: [(Date, Double)]) -> (up: [(Date, Double)], lo: [(Date, Double)]) {
        var up: [(Date, Double)] = []
        var lo: [(Date, Double)] = []
        var win: [Double] = []
        var sum = 0.0, sq = 0.0
        for (d, v) in pair {
            win.append(v); sum += v; sq += v * v
            if win.count > 60 { let o = win.removeFirst(); sum -= o; sq -= o * o }
            if win.count >= 20 {
                let m = sum / Double(win.count)
                let sd = max(0, sq / Double(win.count) - m * m).squareRoot()
                up.append((d, m + sd)); lo.append((d, m - sd))
            }
        }
        return (up, lo)
    }

    private var pcrPanel: some View {
        let shfe = store.cot.pcr.shfe
        // 原始序列 (未降采样, 轨道按原始点滚动计算)
        let volAll: [(Date, Double)] = shfe.compactMap { p in p.vol.map { (p.date, $0) } }
        let oiAll: [(Date, Double)] = shfe.map { ($0.date, $0.oi) }
        let gldAll: [(Date, Double)] = store.cot.pcr.gld.map { ($0.date, $0.value) }
        let shfeDs = downsample(shfe.filter { window.contains($0.date) })
        let gld = downsample(store.cot.pcr.gld.filter { window.contains($0.date) })
            .map { ($0.date, $0.value) }
        var arr: [CanvasSeries] = []
        if !hiddenPCR.contains("沪金成交量 PCR") {
            let pts = shfeDs.compactMap { p -> (Date, Double)? in
                guard let v = p.vol else { return nil }
                return (p.date, v)
            }
            arr.append(CanvasSeries(name: "沪金成交量 PCR", color: C.mm, points: pts))
        }
        if !hiddenPCR.contains("沪金持仓量 PCR") {
            arr.append(CanvasSeries(name: "沪金持仓量 PCR", color: C.gold, dashed: true,
                                    points: shfeDs.map { ($0.date, $0.oi) }))
        }
        if !hiddenPCR.contains("美国 GLD PCR") {
            arr.append(CanvasSeries(name: "美国 GLD PCR", color: C.gldPcr, points: gld))
        }
        // 三条中恰好单独显示一条时, 叠加 ±1σ 上下轨 (灰色虚线, 与网页一致)
        let visible = [hiddenPCR.contains("沪金成交量 PCR") ? [] : volAll,
                       hiddenPCR.contains("沪金持仓量 PCR") ? [] : oiAll,
                       hiddenPCR.contains("美国 GLD PCR") ? [] : gldAll]
            .filter { !$0.isEmpty }
        if visible.count == 1 {
            let b = pcrStdBands(visible[0])
            arr.append(CanvasSeries(name: "±1σ 上轨", color: .gray, dashed: true,
                                    points: downsample(b.up.filter { window.contains($0.0) })))
            arr.append(CanvasSeries(name: "±1σ 下轨", color: .gray, dashed: true,
                                    points: downsample(b.lo.filter { window.contains($0.0) })))
        }
        return Panel(title: "黄金期权 PCR (看跌/看涨)", height: 200) {
            VStack(spacing: 4) {
                LegendToggle(items: [("沪金成交量 PCR", C.mm),
                                     ("沪金持仓量 PCR", C.gold),
                                     ("美国 GLD PCR", C.gldPcr)],
                             hidden: $hiddenPCR)
                MultiLineCanvas(left: arr, hLine: (1.0, "1.0"), height: 158)
            }
        }
    }
}
