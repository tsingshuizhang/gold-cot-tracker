import SwiftUI
import Charts

// MARK: - 颜色 (与网页看板一致)

enum C {
    static let mm = Color(hex: 0xe74c3c)
    static let pm = Color(hex: 0x27ae60)
    static let swap = Color(hex: 0x2980b9)
    static let oth = Color(hex: 0x9b59b6)
    static let nr = Color(hex: 0x7f8c8d)
    static let gold = Color(hex: 0xf39c12)
    static let dxy = Color(hex: 0x16a085)
    static let gldPcr = Color(hex: 0x27ae60)
    static let panelBg = Color(hex: 0xffffff)
    static let axis = Color(hex: 0x8a94a6)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

// MARK: - 通用小组件

/// 单轴图容器 (带标题)
struct Panel<Content: View>: View {
    let title: String
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline).bold()
                .padding(.horizontal, 4)
            content
                .frame(height: height)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(C.panelBg)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                )
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// 数值标签: 带千分位
func fmt(_ v: Double) -> String {
    v.formatted(.number.grouping(.automatic))
}

// MARK: - 时间范围滑轨 (双滑块, 模拟网页 dataZoom)

struct RangeSlider: View {
    @Binding var range: ClosedRange<Double>
    var label: String? = nil            // 当前选中区间文字 (如 2016-10 ~ 2026-09)
    private let minSpan = 0.05
    private let thumb: CGFloat = 20
    private let pad: CGFloat = 44   // 滑轨行高 (整行可拖)
    private let commitInterval = 0.06   // 图表更新节流: 拖动中最多 ~17次/秒, 保证跟手

    // 拖动中的实时位置 (只驱动滑块显示, 不等图表), nil = 未拖动
    @State private var liveLo: Double?
    @State private var liveHi: Double?
    @State private var active: Int?          // 0=左滑块 1=右滑块 (触摸起始点较近的一侧)
    @State private var lastCommit = Date.distantPast

    var body: some View {
        VStack(spacing: 3) {
            if let label {
                Text(label)
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1)
            }
            sliderBody
        }
        .padding(.horizontal)
    }

    private var sliderBody: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // 滑块位置优先用拖动中的实时值, 图表绑定(range)节流更新
            let curLo = liveLo ?? range.lowerBound
            let curHi = liveHi ?? range.upperBound
            let lo = CGFloat(curLo) * (w - thumb) + thumb / 2
            let hi = CGFloat(curHi) * (w - thumb) + thumb / 2
            ZStack {
                Capsule().fill(Color(.systemGray5)).frame(height: 5)
                // 金色选中段: 显式定位在两滑块之间 (ZStack默认居中会导致脱节)
                Capsule().fill(C.gold)
                    .frame(width: max(hi - lo, 0), height: 5)
                    .position(x: (lo + hi) / 2, y: geo.size.height / 2)
                // 滑块纯视觉; 手势统一挂在下方静止的滑轨上, 避免移动参考系导致定位漂移
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1.5)
                    .frame(width: thumb, height: thumb)
                    .position(x: lo, y: geo.size.height / 2)
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1.5)
                    .frame(width: thumb, height: thumb)
                    .position(x: hi, y: geo.size.height / 2)
            }
            // 静止参考系上的单一手势: v.location 绝对坐标, 无反馈回环
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard w > thumb else { return }
                    let val = Double(min(max(v.location.x - thumb / 2, 0), w - thumb) / (w - thumb))
                    if active == nil {
                        // 起始触摸离哪侧近就拖哪侧
                        active = abs(v.location.x - lo) <= abs(v.location.x - hi) ? 0 : 1
                    }
                    if active == 0 {
                        let cap = (liveHi ?? range.upperBound) - minSpan
                        let newLo = min(max(val, 0), cap)
                        liveLo = newLo
                        let now = Date()
                        if now.timeIntervalSince(lastCommit) >= commitInterval {
                            lastCommit = now
                            range = newLo...(liveHi ?? range.upperBound)
                        }
                    } else {
                        let floor = (liveLo ?? range.lowerBound) + minSpan
                        let newHi = max(min(val, 1), floor)
                        liveHi = newHi
                        let now = Date()
                        if now.timeIntervalSince(lastCommit) >= commitInterval {
                            lastCommit = now
                            range = (liveLo ?? range.lowerBound)...newHi
                        }
                    }
                }
                .onEnded { _ in
                    if active == 0, let l = liveLo {
                        range = l...(liveHi ?? range.upperBound)
                    } else if active == 1, let h = liveHi {
                        range = (liveLo ?? range.lowerBound)...h
                    }
                    active = nil; liveLo = nil; liveHi = nil
                    lastCommit = .distantPast
                })
        }
        .frame(height: pad)  // 显式高度: 防止在 ScrollView 内无限伸展
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 双击复位: 恢复完整时间范围
            liveLo = nil; liveHi = nil; active = nil
            range = 0...1
        }
        .padding(.horizontal)
    }
}

// MARK: - 可点击图例 (点击显隐对应线条, 模拟网页 legend)

struct LegendToggle: View {
    let items: [(String, Color)]
    @Binding var hidden: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.chunked(4).enumerated()), id: \.offset) { _, chunk in
                HStack(spacing: 8) {
                    ForEach(chunk, id: \.0) { name, color in
                        Button {
                            if hidden.contains(name) { hidden.remove(name) }
                            else { hidden.insert(name) }
                        } label: {
                            HStack(spacing: 4) {
                                Circle().fill(color).frame(width: 7, height: 7)
                                Text(name).font(.caption2)
                            }
                            .opacity(hidden.contains(name) ? 0.35 : 1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - 时间窗口过滤

extension Date {
    /// 归一化 [0,1] 区间 -> 日期窗口
    func window(_ r: ClosedRange<Double>, in domain: ClosedRange<Date>) -> ClosedRange<Date> {
        let span = domain.upperBound.timeIntervalSince1970 - domain.lowerBound.timeIntervalSince1970
        let lo = domain.lowerBound.addingTimeInterval(r.lowerBound * span)
        let hi = domain.lowerBound.addingTimeInterval(r.upperBound * span)
        return lo...hi
    }
}


// MARK: - 降采样 (手机屏 ~400pt, 每图最多 n 点视觉无损)

func downsample<T>(_ arr: [T], max n: Int = 150) -> [T] {
    guard arr.count > n else { return arr }
    let step = Double(arr.count) / Double(n)
    var out = (0..<n).map { arr[Int(Double($0) * step)] }
    if let last = arr.last { out.append(last) }
    return out
}

/// K线专用: 桶内聚合 (开=首, 收=末, 高=最高, 低=最低), 保形降采样
func downsampleOhlc(_ arr: [Ohlc], max n: Int = 300) -> [Ohlc] {
    guard arr.count > n else { return arr }
    let bucket = arr.count / n
    var out: [Ohlc] = []
    out.reserveCapacity(n + 1)
    var i = 0
    while i < arr.count {
        let end = min(i + bucket, arr.count)
        let seg = arr[i..<end]
        out.append(Ohlc(date: seg.first!.date, open: seg.first!.open,
                        close: seg.last!.close,
                        high: seg.map(\.high).max()!,
                        low: seg.map(\.low).min()!))
        i = end
    }
    return out
}


// MARK: - Canvas 通用图表 (O(n) 路径绘制, 无 mark 开销, 大数据量也不卡)

struct CanvasSeries {
    var name: String
    var color: Color
    var dashed: Bool = false
    var points: [(Date, Double)]   // 已按窗口过滤+降采样
}

func fmtAxis(_ v: Double) -> String {
    if abs(v) >= 10000 { return String(format: "%.0fk", v / 1000) }
    if abs(v) >= 100 { return String(format: "%.0f", v) }
    if abs(v) >= 10 { return String(format: "%.1f", v) }
    return String(format: "%.2f", v)
}

/// Y 轴刻度标签列 — 用纯 SwiftUI Text 实现 (Canvas 内逐帧解析 Text 非常慢, 是拖动卡顿主因)
/// 数值变化时才更新文字; 位置与 Canvas 网格线对齐 (frac 0 = 底部)
struct YAxisLabels: View {
    let lo: Double
    let hi: Double
    var count: Int = 4
    var side: HorizontalEdge = .leading   // 左轴文字右对齐, 右轴文字左对齐

    var body: some View {
        GeometryReader { geo in
            let H = geo.size.height
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let frac = Double(i) / Double(count - 1)
                    Text(fmtAxis(lo + (hi - lo) * frac))
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 40, alignment: side == .leading ? .trailing : .leading)
                        .position(x: 22, y: H * (1 - frac))
                }
            }
        }
        .frame(width: 44)
    }
}

/// 找日期最接近的点 (序列按日期升序)
func nearest(_ pts: [(Date, Double)], to d: Date) -> (Date, Double)? {
    guard var best = pts.first else { return nil }
    var bd = abs(best.0.timeIntervalSince(d))
    for p in pts.dropFirst() {
        let dd = abs(p.0.timeIntervalSince(d))
        if dd < bd { bd = dd; best = p }
    }
    return best
}

/// 浮窗数值格式化: 大数取整带千分位, 小数保留2位
func fmtTip(_ v: Double) -> String {
    abs(v) >= 1000
        ? v.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
        : String(format: "%.2f", v)
}

/// 图表悬浮窗 (与网页 hover 提示同功能): 日期 + 各序列取值
struct ChartTooltip: View {
    let date: Date
    let rows: [(String, Color, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DateUtil.short.string(from: date)).font(.caption2).bold()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 4) {
                    Circle().fill(r.1).frame(width: 5, height: 5)
                    Text(r.0).font(.caption2).foregroundColor(.primary)
                    Text(r.2).font(.caption2).bold()
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground).opacity(0.93))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        )
    }
}

/// 多序列折线/柱状/面积图, 支持右轴双轴. Canvas 内只画路径, 文字全部在轴标签列.
/// 长按出十字光标+数值浮窗 (与网页 hover tooltip 同功能)
struct MultiLineCanvas: View {
    var left: [CanvasSeries] = []
    var right: [CanvasSeries] = []
    var bars: [(Date, Double)] = []        // 左轴柱 (正负着色)
    var barName: String? = nil             // 柱序列名 (浮窗显示用)
    var fillFirst: Bool = false            // 首条左轴序列面积填充
    var hLine: (value: Double, label: String)? = nil
    var height: CGFloat
    var xDomain: ClosedRange<Date>? = nil  // 显式 X 轴域; nil = 取数据范围

    @State private var press: CGPoint?     // 按压位置
    @State private var inspecting = false  // 长按进入十字光标模式

    /// 左轴域 (刻度标签与网格线共用)
    private var leftDom: (lo: Double, hi: Double) {
        var lv: [Double] = bars.map(\.1)
        for s in left { lv += s.points.map(\.1) }
        var lo = lv.min() ?? 0, hi = lv.max() ?? 1
        if !bars.isEmpty || hLine != nil { lo = min(lo, 0); hi = max(hi, hLine?.value ?? 0) }
        let pad = (hi - lo) * 0.08 + 1e-9
        return (lo - pad, hi + pad)
    }

    private var rightDom: (lo: Double, hi: Double)? {
        let rv = right.flatMap { $0.points.map(\.1) }
        guard let lo0 = rv.min(), let hi0 = rv.max() else { return nil }
        let pad = (hi0 - lo0) * 0.08 + 1e-9
        return (lo0 - pad, hi0 + pad)
    }

    private var xExtent: ClosedRange<Date>? {
        if let xd = xDomain { return xd }
        var dates: [Date] = bars.map(\.0)
        for s in left + right { dates += s.points.map(\.0) }
        guard let a = dates.min(), let b = dates.max(), b > a else { return nil }
        return a...b
    }

    /// 十字光标位置 -> 浮窗数据
    private func tooltip(at px: CGFloat, padL: CGFloat, plotW: CGFloat,
                         ext: ClosedRange<Date>) -> (Date, [(String, Color, String)])? {
        guard px >= padL, px <= padL + plotW else { return nil }
        let span = ext.upperBound.timeIntervalSince(ext.lowerBound)
        let date = ext.lowerBound.addingTimeInterval(Double(px - padL) / Double(plotW) * span)
        var rows: [(String, Color, String)] = []
        if let bn = barName, let p = nearest(bars, to: date) { rows.append((bn, C.mm, fmtTip(p.1))) }
        for s in left + right {
            guard let p = nearest(s.points, to: date) else { continue }
            rows.append((s.name, s.color, fmtTip(p.1)))
        }
        guard !rows.isEmpty else { return nil }
        return (date, rows)
    }

    var body: some View {
        let ld = leftDom
        HStack(spacing: 0) {
            YAxisLabels(lo: ld.lo, hi: ld.hi)
            GeometryReader { geo in
                let padL: CGFloat = 4
                let padR: CGFloat = 4
                let plotW = geo.size.width - padL - padR
                ZStack(alignment: .top) {
                    Canvas { ctx, size in
                        let padT: CGFloat = 6
                        let padB: CGFloat = 6
                        let plotH = size.height - padT - padB
                        guard plotW > 10, plotH > 10, let ext = xExtent else { return }
                        let dLo = ext.lowerBound, dHi = ext.upperBound
                        let dSpan = dHi.timeIntervalSince(dLo)
                        func X(_ d: Date) -> CGFloat { padL + CGFloat(d.timeIntervalSince(dLo) / dSpan) * plotW }
                        func YL(_ v: Double) -> CGFloat { padT + CGFloat(1 - (v - ld.lo) / (ld.hi - ld.lo)) * plotH }
                        // 网格线 (无数值文字)
                        for i in 0...3 {
                            let v = ld.lo + (ld.hi - ld.lo) * Double(i) / 3
                            let y = YL(v)
                            var p = Path()
                            p.move(to: CGPoint(x: padL, y: y)); p.addLine(to: CGPoint(x: padL + plotW, y: y))
                            ctx.stroke(p, with: .color(Color(.systemGray5)), style: StrokeStyle(lineWidth: 0.5))
                        }
                        // 柱
                        if !bars.isEmpty {
                            let bw = max(plotW / CGFloat(bars.count) * 0.6, 1)
                            for (d, v) in bars {
                                let x = X(d)
                                let r = CGRect(x: x - bw / 2, y: min(YL(0), YL(v)),
                                               width: bw, height: max(abs(YL(v) - YL(0)), 1))
                                ctx.fill(Path(r), with: .color(v >= 0 ? C.mm : C.pm))
                            }
                        }
                        // 面积填充 (首序列)
                        if fillFirst, let f = left.first, f.points.count > 1 {
                            var path = Path()
                            path.move(to: CGPoint(x: X(f.points[0].0), y: YL(0)))
                            for (d, v) in f.points { path.addLine(to: CGPoint(x: X(d), y: YL(v))) }
                            path.addLine(to: CGPoint(x: X(f.points.last!.0), y: YL(0)))
                            ctx.fill(path, with: .color(f.color.opacity(0.25)))
                        }
                        // 折线
                        func draw(_ s: CanvasSeries, _ Y: (Double) -> CGFloat) {
                            guard s.points.count > 1 else { return }
                            var path = Path()
                            path.move(to: CGPoint(x: X(s.points[0].0), y: Y(s.points[0].1)))
                            for (d, v) in s.points.dropFirst() { path.addLine(to: CGPoint(x: X(d), y: Y(v))) }
                            ctx.stroke(path, with: .color(s.color),
                                       style: StrokeStyle(lineWidth: 1.2, dash: s.dashed ? [4, 3] : []))
                        }
                        for s in left { draw(s, YL) }
                        // 右轴
                        if let rd = rightDom {
                            let rv = right.flatMap { $0.points.map(\.1) }
                            if !rv.isEmpty {
                                func YR(_ v: Double) -> CGFloat { padT + CGFloat(1 - (v - rd.lo) / (rd.hi - rd.lo)) * plotH }
                                for s in right { draw(s, YR) }
                            }
                        }
                        // 基准线 (仅一条文字, 量小留在 Canvas 内)
                        if let hl = hLine {
                            let y = YL(hl.value)
                            var p = Path()
                            p.move(to: CGPoint(x: padL, y: y)); p.addLine(to: CGPoint(x: padL + plotW, y: y))
                            ctx.stroke(p, with: .color(.gray.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                            ctx.draw(Text(hl.label).font(.system(size: 8)).foregroundColor(.gray),
                                     at: CGPoint(x: padL + plotW - 2, y: y), anchor: .trailing)
                        }
                        // 十字光标: 竖线 + 各序列圆点
                        if inspecting, let px = press?.x {
                            var cp = Path()
                            cp.move(to: CGPoint(x: px, y: padT)); cp.addLine(to: CGPoint(x: px, y: padT + plotH))
                            ctx.stroke(cp, with: .color(.gray.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                            let cd = dLo.addingTimeInterval(Double(px - padL) / Double(plotW) * dSpan)
                            for s in left {
                                guard let p = nearest(s.points, to: cd) else { continue }
                                let c = CGPoint(x: X(p.0), y: YL(p.1))
                                ctx.fill(Path(CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)),
                                         with: .color(s.color))
                            }
                            if let rd = rightDom {
                                func YR2(_ v: Double) -> CGFloat { padT + CGFloat(1 - (v - rd.lo) / (rd.hi - rd.lo)) * plotH }
                                for s in right {
                                    guard let p = nearest(s.points, to: cd) else { continue }
                                    let c = CGPoint(x: X(p.0), y: YR2(p.1))
                                    ctx.fill(Path(CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)),
                                             with: .color(s.color))
                                }
                            }
                        }
                    }
                    .frame(height: height)
                    .simultaneousGesture(
                        SimultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { press = $0.location }
                                .onEnded { _ in press = nil; inspecting = false },
                            LongPressGesture(minimumDuration: 0.35)
                                .onEnded { _ in inspecting = true }
                        )
                        )
                    // 数值浮窗
                    if inspecting, let px = press?.x, plotW > 10, let ext = xExtent,
                       let tip = tooltip(at: px, padL: padL, plotW: plotW, ext: ext) {
                        ChartTooltip(date: tip.0, rows: tip.1)
                            .position(x: min(max(px, 86), geo.size.width - 86), y: 12)
                    }
                }
            }
            .frame(height: height)
            if let rd = rightDom {
                YAxisLabels(lo: rd.lo, hi: rd.hi, side: .trailing)
            }
        }
    }
}

/// 日期数组中最近的索引
func nearestIndex(_ dates: [Date], to d: Date) -> Int? {
    guard !dates.isEmpty else { return nil }
    var bi = 0
    var bd = abs(dates[0].timeIntervalSince(d))
    for (i, dt) in dates.enumerated() {
        let dd = abs(dt.timeIntervalSince(d))
        if dd < bd { bd = dd; bi = i }
    }
    return bi
}

/// MACD 专用 Canvas (柱 + DIF/DEA + 金叉死叉标注); 文字标签仅限最近10个, 其余只画圆点
/// 长按出十字光标+数值浮窗
struct MacdCanvas: View {
    var dates: [Date]
    var hist: [Double]
    var dif: [Double]
    var dea: [Double]
    var crosses: [(date: Date, value: Double, kind: String)]
    var hidden: Set<String>
    var height: CGFloat
    var xDomain: ClosedRange<Date>? = nil

    @State private var press: CGPoint?
    @State private var inspecting = false

    private var dom: (lo: Double, hi: Double) {
        var lv = hist + dif + dea
        lv.append(0)
        let lo0 = lv.min() ?? 0, hi0 = lv.max() ?? 1
        let pad = (hi0 - lo0) * 0.1 + 1e-9
        return (lo0 - pad, hi0 + pad)
    }

    /// 十字光标处各指标取值 (浮窗数据)
    private func macdTooltip(at px: CGFloat, padL: CGFloat, plotW: CGFloat)
        -> (Date, [(String, Color, String)])? {
        guard inspecting, plotW > 10, !dates.isEmpty else { return nil }
        let dLo = xDomain?.lowerBound ?? dates.first!
        let dHi = xDomain?.upperBound ?? dates.last!
        guard dHi > dLo else { return nil }
        let cd = dLo.addingTimeInterval(Double(px - padL) / Double(plotW) * dHi.timeIntervalSince(dLo))
        guard let i = nearestIndex(dates, to: cd) else { return nil }
        var rows: [(String, Color, String)] = []
        if !hidden.contains("DIF"), i < dif.count {
            rows.append(("DIF", .red, fmtTip(dif[i])))
        }
        if !hidden.contains("DEA"), i < dea.count {
            rows.append(("DEA", .blue, fmtTip(dea[i])))
        }
        if !hidden.contains("MACD 柱"), i < hist.count {
            rows.append(("MACD 柱", hist[i] >= 0 ? C.mm : C.pm, fmtTip(hist[i])))
        }
        guard !rows.isEmpty else { return nil }
        return (dates[i], rows)
    }

    var body: some View {
        let d = dom
        HStack(spacing: 0) {
            YAxisLabels(lo: d.lo, hi: d.hi, count: 3)
            GeometryReader { geo in
                let padL: CGFloat = 4
                let padR: CGFloat = 4
                let plotW = geo.size.width - padL - padR
                ZStack(alignment: .top) {
                    Canvas { ctx, size in
                        let padT: CGFloat = 14
                        let padB: CGFloat = 6
                        let plotH = size.height - padT - padB
                        guard plotW > 10, plotH > 10, !dates.isEmpty else { return }
                        let dLo = xDomain?.lowerBound ?? dates.first!
                        let dHi = xDomain?.upperBound ?? dates.last!
                        guard dHi > dLo else { return }
                        let dSpan = dHi.timeIntervalSince(dLo)
                        func X(_ dte: Date) -> CGFloat { padL + CGFloat(dte.timeIntervalSince(dLo) / dSpan) * plotW }
                        func Y(_ v: Double) -> CGFloat { padT + CGFloat(1 - (v - d.lo) / (d.hi - d.lo)) * plotH }
                        // 网格线 (无数值文字)
                        for i in 0...2 {
                            let v = d.lo + (d.hi - d.lo) * Double(i) / 2
                            let y = Y(v)
                            var p = Path()
                            p.move(to: CGPoint(x: padL, y: y)); p.addLine(to: CGPoint(x: padL + plotW, y: y))
                            ctx.stroke(p, with: .color(Color(.systemGray5)), style: StrokeStyle(lineWidth: 0.5))
                        }
                        // 柱
                        if !hidden.contains("MACD 柱") {
                            let bw = max(plotW / CGFloat(max(hist.count, 1)) * 0.5, 1)
                            for (i, v) in hist.enumerated() {
                                guard i < dates.count else { break }
                                let r = CGRect(x: X(dates[i]) - bw / 2, y: min(Y(0), Y(v)),
                                               width: bw, height: max(abs(Y(v) - Y(0)), 1))
                                ctx.fill(Path(r), with: .color((v >= 0 ? C.mm : C.pm).opacity(0.5)))
                            }
                        }
                        // DIF / DEA
                        func line(_ vals: [Double], _ color: Color) {
                            var path = Path()
                            for (i, v) in vals.enumerated() {
                                guard i < dates.count else { break }
                                let pt = CGPoint(x: X(dates[i]), y: Y(v))
                                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                            }
                            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2))
                        }
                        if !hidden.contains("DIF") { line(dif, .red) }
                        if !hidden.contains("DEA") { line(dea, .blue) }
                        // 金叉/死叉: 全部画圆点; 文字只标最近10个 (Canvas内Text很慢)
                        if !hidden.contains("金叉/死叉") {
                            for c in crosses {
                                let pt = CGPoint(x: X(c.date), y: Y(c.value))
                                let dd = CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)
                                ctx.fill(Path(dd), with: .color(c.kind == "金叉" ? C.mm : C.pm))
                            }
                            for c in crosses.suffix(10) {
                                let pt = CGPoint(x: X(c.date), y: Y(c.value))
                                ctx.draw(Text(c.kind).font(.system(size: 8))
                                            .foregroundColor(c.kind == "金叉" ? C.mm : C.pm),
                                         at: CGPoint(x: pt.x, y: pt.y - 10))
                            }
                        }
                        // 十字光标
                        if inspecting, let px = press?.x {
                            var cp = Path()
                            cp.move(to: CGPoint(x: px, y: padT)); cp.addLine(to: CGPoint(x: px, y: padT + plotH))
                            ctx.stroke(cp, with: .color(.gray.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                            let cd = dLo.addingTimeInterval(Double(px - padL) / Double(plotW) * dSpan)
                            if let i = nearestIndex(dates, to: cd) {
                                if !hidden.contains("DIF"), i < dif.count {
                                    let c = CGPoint(x: X(dates[i]), y: Y(dif[i]))
                                    ctx.fill(Path(CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.red))
                                }
                                if !hidden.contains("DEA"), i < dea.count {
                                    let c = CGPoint(x: X(dates[i]), y: Y(dea[i]))
                                    ctx.fill(Path(CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.blue))
                                }
                            }
                        }
                    }
                    .frame(height: height)
                    .simultaneousGesture(
                        SimultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { press = $0.location }
                                .onEnded { _ in press = nil; inspecting = false },
                            LongPressGesture(minimumDuration: 0.35)
                                .onEnded { _ in inspecting = true }
                        )
                        )
                    // 数值浮窗
                    if inspecting, let px = press?.x,
                       let tip = macdTooltip(at: px, padL: padL, plotW: plotW) {
                        ChartTooltip(date: tip.0, rows: tip.1)
                            .position(x: min(max(px, 86), geo.size.width - 86), y: 12)
                    }
                }
            }
            .frame(height: height)
        }
    }
}

extension Array {
    /// 每 n 个一组 (图例换行用)
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
