import SwiftUI
import Charts

// MARK: - 持仓看板页 (与网页 dashboard.html 同功能)

struct DashboardView: View {
    @EnvironmentObject private var store: DataStore
    @State private var dim: Dim = .week

    var series: [CotRecord] { store.cotSeries(dim: dim) }

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
            }
        }
        .navigationTitle("黄金 CFTC COT 持仓看板")
        .refreshable { await store.refresh() }
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

    // MARK: 图1: 管理基金净持仓 vs 金价 (双轴)

    private var netPanel: some View {
        Panel(title: "管理基金(机构大资金)净持仓 vs 金价", height: 200) {
            DualAxisChart(height: 200) {
                Chart(series) { r in
                    BarMark(x: .value("日期", r.date), y: .value("净持仓", r.net))
                        .foregroundStyle(r.net >= 0 ? C.mm : C.pm)
                }
                .chartLegend(.hidden)
            } right: {
                Chart(store.cot.price) { p in
                    LineMark(x: .value("日期", p.date), y: .value("金价", p.value))
                        .foregroundStyle(C.gold)
                }
                .chartLegend(.hidden)
            }
        }
    }

    // MARK: 图2: 各类交易者净持仓对比

    private struct CatPoint: Identifiable {
        let id = UUID()
        let date: Date
        let series: String
        let value: Double
    }

    private var categoryPanel: some View {
        let pts = series.flatMap { r in
            [("管理基金(机构)", r.net, C.mm),
             ("生产商/贸易商(套保)", r.pm, C.pm),
             ("掉期交易商", r.swap, C.swap),
             ("其他报告(中小投机)", r.oth, C.oth),
             ("散户/非报告", r.nr, C.nr)]
                .map { CatPoint(date: r.date, series: $0.0, value: $0.1) }
        }
        let scale = Dictionary(uniqueKeysWithValues:
            [("管理基金(机构)", C.mm), ("生产商/贸易商(套保)", C.pm),
             ("掉期交易商", C.swap), ("其他报告(中小投机)", C.oth),
             ("散户/非报告", C.nr)].map { ($0.0, $0.1) })
        return Panel(title: "各类交易者净持仓对比", height: 160) {
            Chart(pts) { p in
                LineMark(x: .value("日期", p.date), y: .value("净持仓", p.value))
                    .foregroundStyle(by: .value("分类", p.series))
            }
            .chartForegroundStyleScale(scale)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(Color(.systemGray5))
                    AxisValueLabel().foregroundStyle(C.axis)
                }
            }
        }
    }

    // MARK: 图3: 管理基金多空分项

    private var longShortPanel: some View {
        let pts = series.flatMap { r in
            [("多头", r.lo, C.mm), ("空头", r.sh, C.pm)]
                .map { CatPoint(date: r.date, series: $0.0, value: $0.1) }
        }
        return Panel(title: "管理基金多空分项", height: 160) {
            Chart(pts) { p in
                LineMark(x: .value("日期", p.date), y: .value("手", p.value))
                    .foregroundStyle(by: .value("分项", p.series))
            }
            .chartForegroundStyleScale(["多头": C.mm, "空头": C.pm])
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(Color(.systemGray5))
                    AxisValueLabel().foregroundStyle(C.axis)
                }
            }
        }
    }

    // MARK: 图4: 总持仓 OI

    private var oiPanel: some View {
        Panel(title: "总持仓 Open Interest", height: 130) {
            Chart(series) { r in
                AreaMark(x: .value("日期", r.date), y: .value("OI", r.oi))
                    .foregroundStyle(C.swap.opacity(0.3))
                LineMark(x: .value("日期", r.date), y: .value("OI", r.oi))
                    .foregroundStyle(C.swap)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(Color(.systemGray5))
                    AxisValueLabel().foregroundStyle(C.axis)
                }
            }
            .chartLegend(.hidden)
        }
    }

    // MARK: 图5: 金价 vs 美元指数 DXY (双轴)

    private var priceDxyPanel: some View {
        Panel(title: "金价 vs 美元指数 DXY", height: 220) {
            DualAxisChart(height: 220) {
                Chart(store.cot.price) { p in
                    LineMark(x: .value("日期", p.date), y: .value("金价", p.value))
                        .foregroundStyle(C.gold)
                }
                .chartLegend(.hidden)
            } right: {
                Chart(store.cot.dxy) { p in
                    LineMark(x: .value("日期", p.date), y: .value("DXY", p.value))
                        .foregroundStyle(C.dxy)
                }
                .chartLegend(.hidden)
            }
        }
    }

    // MARK: 图6: 黄金期权 PCR

    private var pcrPanel: some View {
        Panel(title: "黄金期权 PCR (看跌/看涨)", height: 180) {
            Chart {
                ForEach(store.cot.pcr.shfe) { p in
                    if let v = p.vol {
                        LineMark(x: .value("日期", p.date), y: .value("PCR", v))
                            .foregroundStyle(C.mm)
                    }
                    LineMark(x: .value("日期", p.date), y: .value("PCR", p.oi))
                        .foregroundStyle(C.gold)
                        .lineStyle(StrokeStyle(dash: [4, 3]))
                }
                ForEach(store.cot.pcr.gld) { p in
                    LineMark(x: .value("日期", p.date), y: .value("PCR", p.value))
                        .foregroundStyle(C.gldPcr)
                }
                RuleMark(y: .value("基准", 1.0))
                    .foregroundStyle(.gray).lineStyle(StrokeStyle(dash: [4, 3]))
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
            .chartForegroundStyleScale([
                "沪金期权成交量 PCR": C.mm, "沪金期权持仓量 PCR": C.gold,
                "美国 GLD 期权 PCR": C.gldPcr,
            ])
        }
    }
}
