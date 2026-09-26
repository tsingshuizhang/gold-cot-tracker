import Foundation

/// 技术指标计算 (与网页 dashboard_ta.html 同口径)
enum Indicators {

    // MARK: - 均线 / 指数均线

    static func sma(_ values: [Double], _ n: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for (i, v) in values.enumerated() {
            sum += v
            if i >= n { sum -= values[i - n] }
            if i >= n - 1 { out[i] = sum / Double(n) }
        }
        return out
    }

    static func ema(_ values: [Double], _ n: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let k = 2.0 / (Double(n) + 1)
        var out = [Double](repeating: values[0], count: values.count)
        for i in 1..<values.count {
            out[i] = values[i] * k + out[i - 1] * (1 - k)
        }
        return out
    }

    // MARK: - MACD (12, 26, 9), 柱 = 2×(DIF−DEA)

    struct Macd {
        let dif, dea, hist: [Double]
        /// 金叉(1)/死叉(-1) 出现的位置索引 (只保留最近 maxCount 个)
        let crosses: [(index: Int, kind: Int)]
    }

    static func macd(_ closes: [Double], maxCross: Int = 60) -> Macd {
        // 空数组时 1..<0 非法区间会崩溃, 提前返回
        guard !closes.isEmpty else { return Macd(dif: [], dea: [], hist: [], crosses: []) }
        let ema12 = ema(closes, 12)
        let ema26 = ema(closes, 26)
        let dif = zip(ema12, ema26).map(-)
        let dea = ema(dif, 9)
        let hist = zip(dif, dea).map { 2 * ($0 - $1) }
        var crosses: [(Int, Int)] = []
        for i in 1..<dif.count {
            if dif[i] > dea[i] && dif[i - 1] <= dea[i - 1] {
                crosses.append((i, 1))      // 金叉
            } else if dif[i] < dea[i] && dif[i - 1] >= dea[i - 1] {
                crosses.append((i, -1))     // 死叉
            }
        }
        if crosses.count > maxCross {
            crosses = Array(crosses.suffix(maxCross))
        }
        return Macd(dif: dif, dea: dea, hist: hist,
                    crosses: crosses.map { ($0.0, $0.1) })
    }

    // MARK: - 布林带 (20, 2)

    struct Boll {
        let mid, upper, lower: [Double?]
    }

    static func boll(_ closes: [Double], n: Int = 20, mult: Double = 2) -> Boll {
        var mid = [Double?](repeating: nil, count: closes.count)
        var upper = mid, lower = mid
        // 数据不足 n 根时返回空指标, 防止 19..<5 这类非法区间崩溃
        guard closes.count >= n else { return Boll(mid: mid, upper: upper, lower: lower) }
        for i in n - 1..<closes.count {
            let win = closes[i - n + 1...i]
            let m = win.reduce(0, +) / Double(n)
            let varc = win.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(n)
            let sd = varc.squareRoot()
            mid[i] = m
            upper[i] = m + mult * sd
            lower[i] = m - mult * sd
        }
        return Boll(mid: mid, upper: upper, lower: lower)
    }

    // MARK: - 日K -> 周K/月K 聚合 (开=首, 收=末, 高=最高, 低=最低)

    static func aggregate(_ ohlc: [Ohlc], period: TaPeriod) -> [Ohlc] {
        guard period != .day else { return ohlc }
        let comps: Set<Calendar.Component> = period == .week
            ? [.yearForWeekOfYear, .weekOfYear]
            : [.year, .month]
        var result: [Ohlc] = []
        var cur: Ohlc?
        var curKey: Set<String>?
        for r in ohlc {
            let c = Calendar.current.dateComponents(comps, from: r.date)
            let key = Set(comps.map { "\($0)=\(c.value(for: $0) ?? -1)" })
            if let g = cur, key != curKey {
                result.append(g)
                cur = nil
            }
            if var g = cur {
                g = Ohlc(date: g.date, open: g.open, close: r.close,
                         high: max(g.high, r.high), low: min(g.low, r.low))
                cur = g
            } else {
                cur = r
            }
            curKey = key
        }
        if let g = cur { result.append(g) }
        return result
    }

    // MARK: - 斐波那契回撤位 (基于给定区间最高/最低)

    static let fibRatios: [Double] = [0.236, 0.382, 0.5, 0.618, 0.786]

    static func fibLevels(_ ohlc: [Ohlc]) -> [Double] {
        guard let hi = ohlc.map({ $0.high }).max(),
              let lo = ohlc.map({ $0.low }).min(), hi > lo else { return [] }
        let diff = hi - lo
        return fibRatios.map { hi - diff * $0 }
    }
}
