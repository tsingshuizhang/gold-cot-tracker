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

/// 双轴叠加图: 左轴主图 + 右轴副图 (金价/DXY 等)
struct DualAxisChart<Left: View, Right: View>: View {
    let height: CGFloat
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        ZStack(alignment: .topLeading) {
            left
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(Color(.systemGray5))
                        AxisTick().foregroundStyle(C.axis)
                        AxisValueLabel().foregroundStyle(C.axis)
                    }
                }
            right
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing) {
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick().foregroundStyle(C.axis)
                        AxisValueLabel().foregroundStyle(C.axis)
                    }
                }
                .allowsHitTesting(false)
        }
        .frame(height: height)
    }
}

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
