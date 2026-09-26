import SwiftUI

/// K线 + 布林带 + 斐波那契回撤位 (Canvas 绘制)
struct CandleChartView: View {
    let ohlc: [Ohlc]
    let boll: Indicators.Boll
    let fibs: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard !ohlc.isEmpty else { return }
            let lo = ohlc.map(\.low).min() ?? 0
            let hi = ohlc.map(\.high).max() ?? 1
            let range = max(hi - lo, 1e-9)
            let pad = range * 0.06
            let y0 = lo - pad, y1 = hi + pad
            let n = ohlc.count
            let bw = size.width / CGFloat(n)
            let cw = max(bw * 0.6, 1)

            func Y(_ v: Double) -> CGFloat {
                size.height - CGFloat((v - y0) / (y1 - y0)) * size.height
            }

            // 斐波那契回撤位 (紫色虚线 + 右侧标注)
            for (i, f) in fibs.enumerated() {
                let ratio = Indicators.fibRatios[i]
                var path = Path()
                path.move(to: CGPoint(x: 0, y: Y(f)))
                path.addLine(to: CGPoint(x: size.width, y: Y(f)))
                ctx.stroke(path, with: .color(.purple.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
                let label = Text(String(format: "%.1f%%  %.0f", ratio * 100, f))
                    .font(.system(size: 9)).foregroundColor(.purple)
                ctx.draw(label, at: CGPoint(x: size.width - 42, y: Y(f) - 6))
            }

            // 布林带
            func line(_ vals: [Double?], color: Color) {
                var path = Path()
                var started = false
                for (i, v) in vals.enumerated() {
                    guard let v = v else { continue }
                    let p = CGPoint(x: CGFloat(i) * bw + bw / 2, y: Y(v))
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
                let x = CGFloat(i) * bw + bw / 2
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
        .drawingGroup()   // Metal 加速: 绘制移到 GPU
    }
}
