import SwiftUI
import AppKit

/// 侧边栏的页面
enum SidebarSection: String, CaseIterable, Identifiable {
    case home
    case nodes
    case subscriptions
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .nodes: return "节点"
        case .subscriptions: return "订阅"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .nodes: return "globe"
        case .subscriptions: return "link"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

/// 主窗口侧边栏：顶部 V 标记 + 紧凑导航项
struct SidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // leading 28 = 导航项容器 14 + 行内 14，与下方导航项的文字/图标左缘对齐
            // App 图标兼作连接开关：点击切换开/关代理
            Button {
                Task { await appState.toggleConnection() }
            } label: {
                if let appIcon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 34, height: 34)
                        // 未连接灰色、连接后彩色（与状态联动）
                        .grayscale(appState.isConnected ? 0 : 1)
                        .opacity(appState.isConnected ? 1 : 0.7)
                        .animation(.easeInOut(duration: 0.2), value: appState.isConnected)
                        .contentShape(Rectangle())
                } else {
                    // 取不到应用图标时的兜底
                    BrandMark(size: 22, isActive: appState.isConnected)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .help(appState.isConnected ? "点击断开代理" : "点击开启代理")
            .padding(.leading, 28)
            .padding(.top, 18)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(SidebarSection.allCases) { section in
                    SidebarRow(
                        title: section.title,
                        symbol: section.systemImage,
                        isSelected: appState.sidebarSelection == section
                    ) {
                        appState.sidebarSelection = section
                    }
                }
            }
            .padding(.horizontal, 14)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffectView(targetAppearance: appState.settings.appearance.nsAppearance))
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }
}

/// 单个导航项：细线小图标 + 紧凑文字，选中用浅 accent 底色
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 21)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(title)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// 让侧边栏带原生半透明材质（.sidebar）。
/// 显式传外观：NSVisualEffectView 不会随 preferredColorScheme 及时切换，
/// 外观变化后如不显式设置会残留旧外观（深色切回浅色时侧边栏仍深）。
private struct VisualEffectView: NSViewRepresentable {
    let targetAppearance: NSAppearance?

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.appearance = targetAppearance
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.appearance = targetAppearance
    }
}
