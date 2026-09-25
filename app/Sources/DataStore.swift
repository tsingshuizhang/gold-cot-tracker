import Foundation
import os

let dbg = Logger(subsystem: "com.tsingshuizhang.GoldCotTracker", category: "debug")

/// 数据服务: 抓取网站已发布的数据 (JSON 端点 + ta_data.js)
@MainActor
final class DataStore: ObservableObject {
    static let base = "https://tsingshuizhang.github.io/gold-cot-tracker"

    @Published var cot = CotPayload()
    @Published var ta = TaPayload()
    @Published var loading = false
    @Published var errorMessage: String?

    /// 时间维度聚合 (与网页一致): 周=原始周频; 月/季/年=取周期最后一期
    func cotSeries(dim: Dim) -> [CotRecord] {
        let src = cot.cot.sorted { $0.date < $1.date }
        switch dim {
        case .week: return src
        case .month: return group(src, by: [.year, .month])
        case .quarter: return group(src, by: [.year, .quarter])
        case .year: return group(src, by: [.year])
        }
    }

    private func group(_ src: [CotRecord], by comps: Set<Calendar.Component>) -> [CotRecord] {
        // 升序遍历: 周期切换时, 前一条记录即为上一周期的最后一期 (与网页口径一致)
        var out: [CotRecord] = []
        var prev: CotRecord?
        var prevKey: Set<String>?
        for r in src {
            let c = Calendar.current.dateComponents(comps, from: r.date)
            let key = Set(comps.map { "\($0)=\(c.value(for: $0) ?? -1)" })
            if let p = prev, key != prevKey { out.append(p) }
            prev = r
            prevKey = key
        }
        if let p = prev { out.append(p) }
        return out
    }

    // MARK: 抓取

    func refresh() async {
        loading = true
        errorMessage = nil
        dbg.log("refresh start")
        // 两个数据源互相独立: 一个失败不影响另一个
        do { self.cot = try await fetchCot(); dbg.log("cot ok: \(self.cot.cot.count)") }
        catch {
            dbg.log("cot fail: \(error.localizedDescription)")
            errorMessage = "持仓数据加载失败: \(error.localizedDescription)"
        }
        do { self.ta = try await fetchTa(); dbg.log("ta ok: \(self.ta.ohlc.count)") }
        catch {
            dbg.log("ta fail: \(error.localizedDescription)")
            if errorMessage == nil {
                errorMessage = "行情数据加载失败: \(error.localizedDescription)"
            }
        }
        loading = false
        dbg.log("refresh done")
    }

    private func fetchCot() async throws -> CotPayload {
        let data = try await Self.get("\(Self.base)/data/cot_data.json")
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        var p = CotPayload()
        p.updated = raw["updated"] as? String ?? ""
        // cot 条目为对象: {d, net, lo, sh, oi, pm, sw, oth, nr}
        if let rows = raw["cot"] as? [[String: Any]] {
            p.cot = rows.compactMap { r in
                guard let ds = r["d"] as? String, let d = DateUtil.parse(ds),
                      let net = r["net"] as? Double, let lo = r["lo"] as? Double,
                      let sh = r["sh"] as? Double, let oi = r["oi"] as? Double,
                      let pm = r["pm"] as? Double, let sw = r["sw"] as? Double,
                      let oth = r["oth"] as? Double, let nr = r["nr"] as? Double
                else { return nil }
                return CotRecord(date: d, net: net, lo: lo, sh: sh, oi: oi,
                                 pm: pm, swap: sw, oth: oth, nr: nr)
            }
        }
        p.price = parsePairs(raw["price"])
        p.dxy = parsePairs(raw["dxy"])
        if let pcr = raw["pcr"] as? [String: Any] {
            if let shfe = pcr["shfe"] as? [[Any]] {
                p.pcr.shfe = shfe.compactMap { r in
                    guard r.count >= 3, let d = DateUtil.parse(r[0] as? String ?? ""),
                          let oi = r[2] as? Double else { return nil }
                    let vol = r[1] as? Double
                    return PcrShfePoint(date: d, vol: vol, oi: oi)
                }
            }
            p.pcr.gld = parsePairs(pcr["comex"])
        }
        return p
    }

    private func fetchTa() async throws -> TaPayload {
        // ta_data.js 内容形如: window.TA_DATA = {...};
        var data = try await Self.get("\(Self.base)/data/ta_data.js")
        var text = String(decoding: data, as: UTF8.self)
        if let range = text.range(of: "=") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasSuffix(";") { text.removeLast() }
        data = Data(text.utf8)

        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var p = TaPayload()
        p.updated = raw["updated"] as? String ?? ""
        if let rows = raw["ohlc"] as? [[Any]] {
            p.ohlc = rows.compactMap { r in
                // [日期, 开, 收, 高, 低]
                guard r.count >= 5, let d = DateUtil.parse(r[0] as? String ?? ""),
                      let o = r[1] as? Double, let c = r[2] as? Double,
                      let h = r[3] as? Double, let l = r[4] as? Double
                else { return nil }
                return Ohlc(date: d, open: o, close: c, high: h, low: l)
            }.sorted { $0.date < $1.date }
        }
        if let cost = raw["cost"] as? [[Any]] {
            p.cost = cost.compactMap { r in
                guard r.count >= 2, let y = r[0] as? Int, let v = r[1] as? Double
                else { return nil }
                return (y, v)
            }.sorted { $0.year < $1.year }
        }
        return p
    }

    private func parsePairs(_ any: Any?) -> [PricePoint] {
        guard let rows = any as? [[Any]] else { return [] }
        return rows.compactMap { r in
            guard r.count >= 2, let d = DateUtil.parse(r[0] as? String ?? ""),
                  let v = r[1] as? Double else { return nil }
            return PricePoint(date: d, value: v)
        }
    }

    private static func get(_ url: String) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

enum Dim: String, CaseIterable, Identifiable {
    case week = "周", month = "月", quarter = "季", year = "年"
    var id: String { rawValue }
}

enum TaPeriod: String, CaseIterable, Identifiable {
    case day = "日K", week = "周K", month = "月K"
    var id: String { rawValue }
}
