import SwiftUI

@main
struct GoldCotTrackerApp: App {
    @StateObject private var store = DataStore()
    @State private var tab = 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                NavigationStack {
                    DashboardView()
                }
                .tabItem { Label("持仓看板", systemImage: "chart.bar.fill") }
                .tag(0)

                NavigationStack {
                    TAView()
                }
                .tabItem { Label("技术分析", systemImage: "chart.xyaxis.line") }
                .tag(1)

                NavigationStack {
                    RealtimeView()
                }
                .tabItem { Label("实时行情", systemImage: "waveform.path.ecg") }
                .tag(2)
            }
            .environmentObject(store)
            .task { await store.refresh() }
        }
    }
}
