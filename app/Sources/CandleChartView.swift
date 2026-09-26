import SwiftUI

/// K线 + 布林带 + 斐波那契回撤位 (Canvas 只画路径, 文字走 SwiftUI overlay)
struct CandleChartView: View {
    let ohlc: [Ohlc]
    let boll: Indicators.Boll
    let fibs: [Double]
    var xDomain: ClosedRange<Date>? = nil   // 显式 X 轴域; nil = 数据范围

    private var yDom: (lo: Double, hi: Double) {
        let lo = ohlc.map(\.low).min() ?? 0
        let hi = ohlc.map(\.high).max() ?? 1
        let pad = max(hi - lo, 1e-9) * 0.06
        return (lo - pad, hi + pad)
    }

    var body: some View {
        let yd = yDom
        HStack(spacing: 0) {
            Spacer().frame(width: 44)   // 与下方图表的 Y 轴标签列对齐
            ZStack {
                Canvas { ctx, size in
                    guard !ohlc.isEmpty else { return }
                    let xLo = xDomain?.lowerBound ?? ohlc.first!.date
                    let xHi = xDomain?.upperBound ?? ohlc.last!.date
                    guard xHi > xLo else { return }
                    let n = ohlc.count
                    let plotW = size.width - 4
                    let bw = max(plotW / CGFloat(max(n, 1)), 0.5)
                    let cw = max(bw * 0.6, 1)

                    func X(_ d: Date) -> CGFloat {
                        2 + CGFloat(d.timeIntervalSince(xLo) / xHi.timeIntervalSince(xLo)) * plotW
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
                }
                // 斐波那契文字标签 (SwiftUI Text, 不随拖动逐帧走 Canvas 文字解析)
                .overlay(
                    GeometryReader { geo in
                        ForEach(Array(fibs.enumerated()), id: \.offset) { i, f in
                            Text(String(format: "%.1f%%  %.0f", Indicators.fibRatios[i] * 100, f))
                                .font(.system(size: 9)).foregroundColor(.purple)
                                .lineLimit(1).fixedSize()
                                .position(x: geo.size.width - 46,
                                          y: geo.size.height
                                          - CGFloat((f - yd.lo) / (yd.hi - yd.lo)) * geo.size.height - 6)
                        }
                    }
                )
            }
        }
    }
}
