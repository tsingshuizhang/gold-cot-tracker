import Foundation

// MARK: - 数据模型 (与网站 data/cot_data.json + data/ta_data.js 对应)

struct CotRecord: Identifiable {
    let id = UUID()
    let date: Date
    let net, lo, sh, oi, pm, swap, oth, nr: Double
}

struct PricePoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct Ohlc: Identifiable {
    let id = UUID()
    let date: Date
    let open, close, high, low: Double
}

struct PcrData {
    var shfe: [PcrShfePoint] = []     // [日期, 成交量PCR, 持仓量PCR]
    var gld: [PricePoint] = []        // 美国 GLD 期权 PCR
}

struct PcrShfePoint: Identifiable {
    let id = UUID()
    let date: Date
    let vol: Double?      // 成交量 PCR (可能为空)
    let oi: Double        // 持仓量 PCR
}

struct CotPayload {
    var updated: String = ""
    var cot: [CotRecord] = []
    var price: [PricePoint] = []
    var dxy: [PricePoint] = []
    var pcr = PcrData()
}

struct TaPayload {
    var updated: String = ""
    var ohlc: [Ohlc] = []
    var cost: [(year: Int, value: Double)] = []
}

// MARK: - 日期工具

enum DateUtil {
    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ s: String) -> Date? { parser.date(from: s) }
}
