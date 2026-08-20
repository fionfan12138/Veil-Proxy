import SwiftUI

/// 主窗口根视图：侧边栏 + 详情
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
                .frame(minWidth: 520, minHeight: 460)
        }
        // 右下角全局提示（切节点 / 端口生效等），任何页面都可见
        .overlay(alignment: .bottomTrailing) {
            if let message = appState.toastMessage {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.toastMessage)
        .onAppear {
            appState.setMainWindowVisible(true)
            // 菜单栏「打开主界面」经此闭包重建/激活窗口
            AppDelegate.shared?.openMainWindowAction = { openWindow(id: "main") }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.sidebarSelection ?? .home {
        case .home: OverviewView()
        case .nodes: NodesView()
        case .subscriptions: SubscriptionsView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}
