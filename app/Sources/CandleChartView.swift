import SwiftUI

/// K线 + 布林带 + 斐波那契回撤位 (Canvas 只画路径, 文字走 SwiftUI overlay)
/// 长按出十字光标 + OHLC 数值浮窗 (与网页 hover 同功能)
struct CandleChartView: View {
    let ohlc: [Ohlc]
    let boll: Indicators.Boll
    let fibs: [Double]
    var xDomain: ClosedRange<Date>? = nil   // 显式 X 轴域; nil = 数据范围

    @State private var press: CGPoint?
    @State private var inspecting = false

    private var yDom: (lo: Double, hi: Double) {
        let lo = ohlc.map(\.low).min() ?? 0
        let hi = ohlc.map(\.high).max() ?? 1
        let pad = max(hi - lo, 1e-9) * 0.06
        return (lo - pad, hi + pad)
    }

    /// 十字光标处最近K线的 OHLC (浮窗数据)
    private func candleTooltip(at px: CGFloat, padL: CGFloat, plotW: CGFloat)
        -> (Date, [(String, Color, String)])? {
        guard inspecting, plotW > 10, !ohlc.isEmpty else { return nil }
        let xLo = xDomain?.lowerBound ?? ohlc.first!.date
        let xHi = xDomain?.upperBound ?? ohlc.last!.date
        guard xHi > xLo else { return nil }
        let cd = xLo.addingTimeInterval(Double(px - padL) / Double(plotW) * xHi.timeIntervalSince(xLo))
        guard let i = nearestIndex(ohlc.map(\.date), to: cd), i < ohlc.count else { return nil }
        let r = ohlc[i]
        let up = r.close >= r.open
        return (r.date, [
            ("开", .secondary, fmtTip(r.open)),
            ("高", C.mm, fmtTip(r.high)),
            ("低", C.pm, fmtTip(r.low)),
            ("收", up ? C.mm : C.pm, fmtTip(r.close)),
        ])
    }

    var body: some View {
        let yd = yDom
        HStack(spacing: 0) {
            Spacer().frame(width: 44)   // 与下方图表的 Y 轴标签列对齐
            GeometryReader { geo in
                let padL: CGFloat = 2
                let plotW = geo.size.width - 4
                ZStack(alignment: .top) {
                    Canvas { ctx, size in
                        guard !ohlc.isEmpty else { return }
                        let xLo = xDomain?.lowerBound ?? ohlc.first!.date
                        let xHi = xDomain?.upperBound ?? ohlc.last!.date
                        guard xHi > xLo, plotW > 10 else { return }
                        let n = ohlc.count
                        let bw = max(plotW / CGFloat(max(n, 1)), 0.5)
                        let cw = max(bw * 0.6, 1)

                        func X(_ d: Date) -> CGFloat {
                            padL + CGFloat(d.timeIntervalSince(xLo) / xHi.timeIntervalSince(xLo)) * plotW
                        }
                        func Y(_ v: Double) -> CGFloat {
                            size.height - CGFloat((v - yd.lo) / (yd.hi - yd.lo)) * size.height
                        }

                        // 斐波那契回撤位 (仅虚线, 文字在 overlay)
                        for f in fibs {
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: Y(f)))
                            path.addLine(to: CGPoint(x: size.width, y: Y(f)))
                            ctx.stroke(path, with: .color(.purple.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
                        }

                        // 布林带 (按日期定位, 与窗口轴对齐)
                        func line(_ vals: [Double?], color: Color) {
                            var path = Path()
                            var started = false
                            for (i, v) in vals.enumerated() {
                                guard let v = v, i < ohlc.count else { continue }
                                let p = CGPoint(x: X(ohlc[i].date), y: Y(v))
                                if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                            }
                            ctx.stroke(path, with: .color(color.opacity(0.7)),
                                       style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                        }
                        line(boll.upper, color: .blue)
                        line(boll.mid, color: .blue)
                        line(boll.lower, color: .blue)

                        // K线
                        for (i, r) in ohlc.enumerated() {
                            let x = X(r.date)
                            let up = r.close >= r.open
                            let color: Color = up ? .red : .green
                            var wick = Path()
                            wick.move(to: CGPoint(x: x, y: Y(r.high)))
                            wick.addLine(to: CGPoint(x: x, y: Y(r.low)))
                            ctx.stroke(wick, with: .color(color), style: StrokeStyle(lineWidth: 1))
                            let bodyTop = Y(max(r.open, r.close))
                            let bodyH = max(abs(Y(r.open) - Y(r.close)), 1)
                            let rect = CGRect(x: x - cw / 2, y: bodyTop, width: cw, height: bodyH)
                            ctx.fill(Path(rect), with: .color(up ? color.opacity(0.85) : color))
                        }

                        // 十字光标: 竖线 + 最近K线高亮
                        if inspecting, let px = press?.x {
                            var cp = Path()
                            cp.move(to: CGPoint(x: px, y: 0)); cp.addLine(to: CGPoint(x: px, y: size.height))
                            ctx.stroke(cp, with: .color(.gray.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                            let cd = xLo.addingTimeInterval(Double(px - padL) / Double(plotW) * xHi.timeIntervalSince(xLo))
                            if let r = nearest(ohlc.map { ($0.date, $0.close) }, to: cd) {
                                if let bar = ohlc.first(where: { $0.date == r.0 }) {
                                    let x = X(bar.date)
                                    let up = bar.close >= bar.open
                                    let hl = CGRect(x: x - 4, y: Y(bar.high), width: 8,
                                                    height: max(Y(bar.low) - Y(bar.high), 1))
                                    ctx.stroke(Path(hl), with: .color(up ? .red : .green),
                                               style: StrokeStyle(lineWidth: 1))
                                }
                            }
                        }
                    }
                    .simultaneousGesture(
                        SimultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { press = $0.location }
                                .onEnded { _ in press = nil; inspecting = false },
                            LongPressGesture(minimumDuration: 0.35)
                                .onEnded { _ in inspecting = true }
                        )
                        )
                    // OHLC 数值浮窗
                    if inspecting, let px = press?.x,
                       let tip = candleTooltip(at: px, padL: padL, plotW: plotW) {
                        ChartTooltip(date: tip.0, rows: tip.1)
                            .position(x: min(max(px, 86), geo.size.width - 86), y: 12)
                    }
                    // 斐波那契文字标签 (SwiftUI Text, 不随拖动逐帧走 Canvas 文字解析)
                    GeometryReader { fibGeo in
                        ForEach(Array(fibs.enumerated()), id: \.offset) { i, f in
                            Text(String(format: "%.1f%%  %.0f", Indicators.fibRatios[i] * 100, f))
                                .font(.system(size: 9)).foregroundColor(.purple)
                                .lineLimit(1).fixedSize()
                                .position(x: fibGeo.size.width - 46,
                                          y: fibGeo.size.height
                                          - CGFloat((f - yd.lo) / (yd.hi - yd.lo)) * fibGeo.size.height - 6)
                        }
                    }
                }
            }
        }
    }
}
