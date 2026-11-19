import SwiftUI
import UIKit

@main
struct GoldCotTrackerApp: App {
    @StateObject private var store = DataStore()
    @State private var tab = 0
    @AppStorage("goldCotTheme") private var theme = "auto"
    @Environment(\.scenePhase) private var scenePhase

    private var preferredScheme: ColorScheme? {
        switch theme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

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
            .preferredColorScheme(preferredScheme)
            .task { await store.refresh() }
            .onChange(of: scenePhase) { _, phase in
                // 回到前台重新拉取已发布数据；避免 App 常驻后台后一直显示旧缓存。
                if phase == .active, store.lastRefresh != nil {
                    Task { await store.refresh() }
                }
            }
        }
    }
}

// MARK: - 三页共用的导航栏操作

struct RefreshButton: View {
    @EnvironmentObject private var store: DataStore

    var body: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(store.loading)
        .accessibilityLabel("刷新数据")
    }
}

struct ThemeToggleButton: View {
    @AppStorage("goldCotTheme") private var theme = "auto"
    @Environment(\.colorScheme) private var systemScheme

    private var isDark: Bool {
        theme == "dark" || (theme == "auto" && systemScheme == .dark)
    }

    var body: some View {
        Menu {
            Picker("外观", selection: $theme) {
                Label("跟随系统", systemImage: "circle.lefthalf.filled").tag("auto")
                Label("浅色", systemImage: "sun.max").tag("light")
                Label("深色", systemImage: "moon").tag("dark")
            }
        } label: {
            Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
        }
        .accessibilityLabel("切换深色或浅色外观")
    }
}

// MARK: - 原生分享与导出

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum AppExport {
    @MainActor
    static func csv(lines: [String], name: String) -> URL? {
        let text = "\u{FEFF}" + lines.joined(separator: "\n")
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            dbg.log("CSV export failed: \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    static func png<Content: View>(of content: Content, name: String) -> URL? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else { return nil }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            dbg.log("PNG export failed: \(error.localizedDescription)")
            return nil
        }
    }
}
