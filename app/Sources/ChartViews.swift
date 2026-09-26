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
    private let minSpan = 0.05
    private let thumb: CGFloat = 20
    private let pad: CGFloat = 44   // 触摸热区 (苹果建议最小 44pt)
    private let commitInterval = 0.06   // 图表更新节流: 拖动中最多 ~17次/秒, 保证跟手

    // 拖动中的实时位置 (只驱动滑块显示, 不等图表), nil = 未拖动
    @State private var liveLo: Double?
    @State private var liveHi: Double?
    @State private var lastCommit = Date.distantPast

    /// 热区中心与滑块圆心重合: 手指全局 x = 圆心x + (局部x - pad/2), 再归一化到 [0,1]
    private func norm(_ locX: CGFloat, _ center: CGFloat, _ w: CGFloat) -> Double {
        let g = center + locX - pad / 2
        return Double(min(max(g - thumb / 2, 0), w - thumb) / (w - thumb))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // 滑块位置优先用拖动中的实时值, 图表绑定(range)节流更新
            let curLo = liveLo ?? range.lowerBound
            let curHi = liveHi ?? range.upperBound
            let lo = CGFloat(curLo) * (w - thumb) + thumb / 2
            let hi = CGFloat(curHi) * (w - thumb) + thumb / 2
            ZStack {
                Capsule().fill(Color(.systemGray5)).frame(height: 5)
                Capsule().fill(C.gold).frame(width: max(hi - lo, 0), height: 5)
                // 左滑块: 视觉 20pt, 热区 44pt
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1.5)
                    .frame(width: thumb, height: thumb)
                    .frame(width: pad, height: pad)
                    .contentShape(Rectangle())
                    .position(x: lo, y: geo.size.height / 2)
                    .highPriorityGesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let val = norm(v.location.x, lo, w)
                            let cap = (liveHi ?? range.upperBound) - minSpan
                            let newLo = min(max(val, 0), cap)
                            liveLo = newLo
                            // 节流提交给图表: 滑块永远实时, 图表最多 17 帧/秒
                            let now = Date()
                            if now.timeIntervalSince(lastCommit) >= commitInterval {
                                lastCommit = now
                                range = newLo...(liveHi ?? range.upperBound)
                            }
                        }
                        .onEnded { _ in
                            if let l = liveLo { range = l...(liveHi ?? range.upperBound) }
                            liveLo = nil; liveHi = nil
                            lastCommit = .distantPast
                        })
                // 右滑块
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1.5)
                    .frame(width: thumb, height: thumb)
                    .frame(width: pad, height: pad)
                    .contentShape(Rectangle())
                    .position(x: hi, y: geo.size.height / 2)
                    .highPriorityGesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let val = norm(v.location.x, hi, w)
                            let floor = (liveLo ?? range.lowerBound) + minSpan
                            let newHi = max(min(val, 1), floor)
                            liveHi = newHi
                            let now = Date()
                            if now.timeIntervalSince(lastCommit) >= commitInterval {
                                lastCommit = now
                                range = (liveLo ?? range.lowerBound)...newHi
                            }
                        }
                        .onEnded { _ in
                            if let h = liveHi { range = (liveLo ?? range.lowerBound)...h }
                            liveLo = nil; liveHi = nil
                            lastCommit = .distantPast
                        })
            }
        }
        .frame(height: pad)  // 显式高度: 容纳热区且防止在 ScrollView 内无限伸展
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

/// 多序列折线/柱状/面积图, 支持右轴双轴
struct MultiLineCanvas: View {
    var left: [CanvasSeries] = []
    var right: [CanvasSeries] = []
    var bars: [(Date, Double)] = []        // 左轴柱 (正负着色)
    var fillFirst: Bool = false            // 首条左轴序列面积填充
    var hLine: (value: Double, label: String)? = nil
    var height: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let padL: CGFloat = 44
            let padR: CGFloat = right.isEmpty ? 8 : 40
            let padT: CGFloat = 6
            let padB: CGFloat = 6
            let plotW = size.width - padL - padR
            let plotH = size.height - padT - padB
            guard plotW > 10, plotH > 10 else { return }
            var dates: [Date] = bars.map(\.0)
            for s in left + right { dates += s.points.map(\.0) }
            guard let dLo = dates.min(), let dHi = dates.max(), dHi > dLo else { return }
            let dSpan = dHi.timeIntervalSince(dLo)
            func X(_ d: Date) -> CGFloat { padL + CGFloat(d.timeIntervalSince(dLo) / dSpan) * plotW }
            // 左轴域
            var lv: [Double] = bars.map(\.1)
            for s in left { lv += s.points.map(\.1) }
            guard var lLo = lv.min(), var lHi = lv.max() else { return }
            if !bars.isEmpty || hLine != nil { lLo = min(lLo, 0); lHi = max(lHi, hLine?.value ?? 0) }
            let lPad = (lHi - lLo) * 0.08 + 1e-9
            lLo -= lPad; lHi += lPad
            func YL(_ v: Double) -> CGFloat { padT + CGFloat(1 - (v - lLo) / (lHi - lLo)) * plotH }
            // 网格 + 左轴标签
            for i in 0...3 {
                let v = lLo + (lHi - lLo) * Double(i) / 3
                let y = YL(v)
                var p = Path()
                p.move(to: CGPoint(x: padL, y: y)); p.addLine(to: CGPoint(x: padL + plotW, y: y))
                ctx.stroke(p, with: .color(Color(.systemGray5)), style: StrokeStyle(lineWidth: 0.5))
                ctx.draw(Text(fmtAxis(v)).font(.system(size: 9)).foregroundColor(.gray),
                         at: CGPoint(x: padL - 4, y: y), anchor: .trailing)
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
            if !right.isEmpty {
                let rv = right.flatMap { $0.points.map(\.1) }
                if let rLo0 = rv.min(), let rHi0 = rv.max() {
                    let rPad = (rHi0 - rLo0) * 0.08 + 1e-9
                    let rLo = rLo0 - rPad, rHi = rHi0 + rPad
                    func YR(_ v: Double) -> CGFloat { padT + CGFloat(1 - (v - rLo) / (rHi - rLo)) * plotH }
                    for i in 0...3 {
                        let v = rLo + (rHi - rLo) * Double(i) / 3
                        ctx.draw(Text(fmtAxis(v)).font(.system(size: 9)).foregroundColor(.gray),
                                 at: CGPoint(x: padL + plotW + 4, y: YR(v)), anchor: .leading)
                    }
                    for s in right { draw(s, YR) }
                }
            }
            // 基准线
            if let hl = hLine {
                let y = YL(hl.value)
                var p = Path()
                p.move(to: CGPoint(x: padL, y: y)); p.addLine(to: CGPoint(x: padL + plotW, y: y))
                ctx.stroke(p, with: .color(.gray.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                ctx.draw(Text(hl.label).font(.system(size: 8)).foregroundColor(.gray),
                         at: CGPoint(x: padL + plotW - 2, y: y), anchor: .trailing)
            }
        }
        .frame(height: height)
        .drawingGroup()   // Metal 加速: 绘制移到 GPU, 大幅减轻主线程负担
    }
}

/// MACD 专用 Canvas (柱 + DIF/DEA + 金叉死叉标注)
struct MacdCanvas: View {
    var dates: [Date]
    var hist: [Double]
    var dif: [Double]
    var dea: [Double]
    var crosses: [(date: Date, value: Double, kind: String)]
    var hidden: Set<String>
    var height: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let padL: CGFloat = 44
            let padR: CGFloat = 8
            let padT: CGFloat = 14
            let padB: CGFloat = 6
            let plotW = size.width - padL - padR
            let plotH = size.height - padT - padB
            guard plotW > 10, plotH > 10, dates.count > 1 else { return }
            let dLo = dates.first!, dHi = dates.last!
            let dSpan = dHi.timeIntervalSince(dLo)
            func X(_ i: Int) -> CGFloat { padL + CGFloat(dates[i].timeIntervalSince(dLo) / dSpan) * plotW }
            var lv = hist + dif + dea
            lv.append(0)
            guard var lLo = lv.min(), var lHi = lv.max() else { return }
            let lPad = (lHi - lLo) * 0.1 + 1e-9
            lLo -= lPad; lHi += lPad
            func Y(_ v: Double) -> CGFloat { padT + CGFloat(1 - (v - lLo) / (lHi - lLo)) * plotH }
            for i in 0...2 {
                let v = lLo + (lHi - lLo) * Double(i) / 2
                let y = Y(v)
                var p = Path()
                p.move(to: CGPoint(x: padL, y: y)); p.addLine(to: CGPoint(x: padL + plotW, y: y))
                ctx.stroke(p, with: .color(Color(.systemGray5)), style: StrokeStyle(lineWidth: 0.5))
                ctx.draw(Text(fmtAxis(v)).font(.system(size: 9)).foregroundColor(.gray),
                         at: CGPoint(x: padL - 4, y: y), anchor: .trailing)
            }
            // 柱
            if !hidden.contains("MACD 柱") {
                let bw = max(plotW / CGFloat(hist.count) * 0.5, 1)
                for (i, v) in hist.enumerated() {
                    let r = CGRect(x: X(i) - bw / 2, y: min(Y(0), Y(v)),
                                   width: bw, height: max(abs(Y(v) - Y(0)), 1))
                    ctx.fill(Path(r), with: .color((v >= 0 ? C.mm : C.pm).opacity(0.5)))
                }
            }
            // DIF / DEA
            func line(_ vals: [Double], _ color: Color) {
                var path = Path()
                for (i, v) in vals.enumerated() {
                    let pt = CGPoint(x: X(i), y: Y(v))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2))
            }
            if !hidden.contains("DIF") { line(dif, .red) }
            if !hidden.contains("DEA") { line(dea, .blue) }
            // 金叉/死叉
            if !hidden.contains("金叉/死叉") {
                for c in crosses {
                    let pt = CGPoint(x: padL + CGFloat(c.date.timeIntervalSince(dLo) / dSpan) * plotW,
                                     y: Y(c.value))
                    let d = CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)
                    ctx.fill(Path(d), with: .color(c.kind == "金叉" ? C.mm : C.pm))
                    ctx.draw(Text(c.kind).font(.system(size: 8))
                                .foregroundColor(c.kind == "金叉" ? C.mm : C.pm),
                             at: CGPoint(x: pt.x, y: pt.y - 10))
                }
            }
        }
        .frame(height: height)
        .drawingGroup()   // Metal 加速
    }
}

extension Array {
    /// 每 n 个一组 (图例换行用)
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
