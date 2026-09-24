import SwiftUI
import Charts

// MARK: - 技术分析页 (与网页 dashboard_ta.html 同功能)

struct TAView: View {
    @EnvironmentObject private var store: DataStore
    @State private var period: TaPeriod = .day

    private var ohlc: [Ohlc] {
        Indicators.aggregate(store.ta.ohlc, period: period)
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
            }
        }
        .navigationTitle("COMEX 黄金技术分析")
        .refreshable { await store.refresh() }
    }

    // MARK: 图1: K线 + 布林带 + 斐波那契 (Canvas 绘制)

    private var candlePanel: some View {
        let boll = Indicators.boll(closes)
        let fibs = Indicators.fibLevels(ohlc)
        return Panel(title: "K线 + 布林带(20,2) + 斐波那契回撤位", height: 320) {
            CandleChartView(ohlc: ohlc, boll: boll, fibs: fibs)
        }
    }

    // MARK: 图2: 收盘价 + 均线 MA5/10/20/60/120/250

    private struct MAPoint: Identifiable {
        let id = UUID()
        let date: Date
        let ma: String
        let value: Double
    }

    private var maPanel: some View {
        let defs: [(String, Int, Color)] = [
            ("MA5", 5, .red), ("MA10", 10, .orange), ("MA20", 20, .blue),
            ("MA60", 60, .green), ("MA120", 120, .purple), ("MA250", 250, .gray),
        ]
        var pts: [MAPoint] = []
        let cl = closes
        for (name, n, _) in defs {
            guard cl.count >= n else { continue }
            let ma = Indicators.sma(cl, n)
            for (i, v) in ma.enumerated() {
                if let v = v { pts.append(MAPoint(date: ohlc[i].date, ma: name, value: v)) }
            }
        }
        let closePts = ohlc.map { MAPoint(date: $0.date, ma: "收盘价", value: $0.close) }
        return Panel(title: "收盘价 + 均线 MA", height: 220) {
            Chart(closePts + pts) { p in
                LineMark(x: .value("日期", p.date), y: .value("价格", p.value))
                    .foregroundStyle(by: .value("序列", p.ma))
            }
            .chartForegroundStyleScale(Dictionary(uniqueKeysWithValues:
                defs.map { ($0.0, $0.2) } + [("收盘价", Color.secondary)]))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(Color(.systemGray5))
                    AxisValueLabel().foregroundStyle(C.axis)
                }
            }
        }
    }

    // MARK: 图3: 金价 vs 行业平均开采成本 (AISC) + 比值 (双轴)

    private var aiscPanel: some View {
        // 比值: 每个价格点除以其年份对应的 AISC
        let ratioPts: [PricePoint] = store.ta.cost.isEmpty ? [] :
            store.cot.price.compactMap { p in
                let y = Calendar.current.component(.year, from: p.date)
                guard let cost = store.ta.cost.last(where: { $0.year <= y })?.value,
                      cost > 0 else { return nil }
                return PricePoint(date: p.date, value: p.value / cost)
            }
        let costPts: [PricePoint] = store.ta.cost.map {
            // 年度阶梯: 用该年年初作为起点展示
            var c = DateComponents(); c.year = $0.year; c.month = 1; c.day = 1
            let d = Calendar.current.date(from: c) ?? Date()
            return PricePoint(date: d, value: $0.value)
        }
        return Panel(title: "金价 vs 行业平均开采成本 (AISC) 及 金价/AISC 比值", height: 200) {
            DualAxisChart(height: 200) {
                Chart {
                    ForEach(store.cot.price) { p in
                        LineMark(x: .value("日期", p.date), y: .value("金价", p.value))
                            .foregroundStyle(C.gold)
                    }
                    ForEach(costPts) { p in
                        LineMark(x: .value("日期", p.date), y: .value("AISC", p.value))
                            .foregroundStyle(.teal)
                            .lineStyle(StrokeStyle(dash: [4, 3]))
                    }
                }
            } right: {
                Chart(ratioPts) { p in
                    LineMark(x: .value("日期", p.date), y: .value("比值", p.value))
                        .foregroundStyle(.brown)
                }
                .chartLegend(.hidden)
            }
        }
    }

    // MARK: 图4: MACD(12,26,9) + 金叉/死叉标注

    private struct CrossPoint: Identifiable {
        let id = UUID()
        let date: Date
        let dif: Double
        let kind: String     // "金叉" / "死叉"
    }

    private var macdPanel: some View {
        let m = Indicators.macd(closes)
        struct MPoint: Identifiable {
            let id = UUID(); let date: Date
            let series: String; let value: Double
        }
        var pts: [MPoint] = []
        for (i, d) in m.dif.enumerated() {
            let date = ohlc[i].date
            pts.append(MPoint(date: date, series: "DIF", value: d))
            pts.append(MPoint(date: date, series: "DEA", value: m.dea[i]))
            pts.append(MPoint(date: date, series: "MACD 柱",
                              value: m.hist[i]))
        }
        let crosses: [CrossPoint] = m.crosses.compactMap { c in
            guard c.index < ohlc.count else { return nil }
            return CrossPoint(date: ohlc[c.index].date, dif: m.dif[c.index],
                              kind: c.kind == 1 ? "金叉" : "死叉")
        }
        return Panel(title: "MACD(12, 26, 9) — 金叉 / 死叉", height: 200) {
            Chart {
                ForEach(pts) { p in
                    if p.series == "MACD 柱" {
                        BarMark(x: .value("日期", p.date), y: .value("值", p.value))
                            .foregroundStyle(p.value >= 0 ? C.mm.opacity(0.5) : C.pm.opacity(0.5))
                    } else {
                        LineMark(x: .value("日期", p.date), y: .value("值", p.value))
                            .foregroundStyle(p.series == "DIF" ? .red : .blue)
                    }
                }
                ForEach(crosses) { c in
                    PointMark(x: .value("日期", c.date), y: .value("值", c.dif))
                        .symbol(.circle)
                        .symbolSize(18)
                        .foregroundStyle(c.kind == "金叉" ? C.mm : C.pm)
                        .annotation(position: .top, spacing: 2) {
                            Text(c.kind).font(.system(size: 8))
                                .foregroundStyle(c.kind == "金叉" ? C.mm : C.pm)
                        }
                    }
                }
                RuleMark(y: .value("零轴", 0)).foregroundStyle(.gray.opacity(0.4))
            }
            .chartXAxis {
                AxisMarks { AxisValueLabel().foregroundStyle(C.axis) }
            }
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(Color(.systemGray5))
                    AxisValueLabel().foregroundStyle(C.axis)
                }
            }
            .chartLegend(.hidden)
        }
    }
