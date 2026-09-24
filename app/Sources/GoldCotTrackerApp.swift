import SwiftUI

@main
struct GoldCotTrackerApp: App {
    @StateObject private var store = DataStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    DashboardView()
                }
                .tabItem { Label("持仓看板", systemImage: "chart.bar.fill") }

                NavigationStack {
                    TAView()
                }
                .tabItem { Label("技术分析", systemImage: "chart.candlestick.chart") }
            }
            .environmentObject(store)
            .task { await store.refresh() }
        }
    }
}
