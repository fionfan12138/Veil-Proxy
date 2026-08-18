import SwiftUI
import AppKit
import Combine

@main
struct VeilApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Window 单窗口场景：openWindow 重复调用只会激活既有窗口，不会新建；
        // 关闭窗口不退出应用（见 AppDelegate.applicationShouldTerminateAfterLastWindowClosed）
        Window("Veil", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 760, height: 560)
        .commands {
            // 快捷键（阶段 3.7）：⌘1-5 切页面；⌘R 各页分工（节点=测速/订阅=全部更新/日志=刷新）
            CommandMenu("代理") {
                Button(appState.isConnected ? "断开代理" : "开启代理") {
                    Task { await appState.toggleConnection() }
                }
                .keyboardShortcut("t", modifiers: .command)

                Divider()

                Button("规则模式") { appState.setMode(.rule) }
                Button("全局模式") { appState.setMode(.global) }
                Button("直连模式") { appState.setMode(.direct) }

                Divider()

                Button("下一个节点") { appState.cycleNode(forward: true) }
                Button("上一个节点") { appState.cycleNode(forward: false) }
            }

            CommandMenu("页面") {
                Button("首页") { appState.sidebarSelection = .home }
                    .keyboardShortcut("1", modifiers: .command)
                Button("节点") { appState.sidebarSelection = .nodes }
                    .keyboardShortcut("2", modifiers: .command)
                Button("订阅") { appState.sidebarSelection = .subscriptions }
                    .keyboardShortcut("3", modifiers: .command)
                Button("日志") { appState.sidebarSelection = .logs }
                    .keyboardShortcut("4", modifiers: .command)
                Button("设置") { appState.sidebarSelection = .settings }
                    .keyboardShortcut("5", modifiers: .command)
            }
        }
    }
}

/// 应用委托：菜单栏状态项（可运行时开关）、Dock 显隐、关闭窗口不退出。
/// 用 NSStatusItem + 原生 NSMenu 替代 MenuBarExtra——MenuBarExtra 无法在运行时隐藏，
/// 而设置里需要「菜单栏图标」开关。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    /// 「打开主界面」动作（ContentView 出现时注入 openWindow 闭包）
    var openMainWindowAction: (() -> Void)?
    private var statusItem: NSStatusItem?
    private var iconObserver: AnyCancellable?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只监听主窗口关闭：关闭后隐藏 Dock 图标（此时无窗口，切策略干净不闪）
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
        // 菜单栏图标永远显示。
        // 启动时**不切换激活策略**：默认 .regular，启动即开的主窗口自然带 Dock 图标；
        // （didFinishLaunching 时窗口尚未创建，此时判定「无窗口」切 accessory 会导致启动后无图标）
        installStatusItem()
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow, window.title == "Veil" else { return }
        AppState.current?.setMainWindowVisible(false)
        // 主窗口正在关闭：直接隐藏 Dock 图标。
        // 不能用 isVisible 判断——willClose 时窗口仍可能报告可见，会导致图标残留
        NSApp.setActivationPolicy(.accessory)
    }

    /// 关闭主窗口不退出（常驻后台；窗口可由菜单栏/重新启动恢复）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Dock / 菜单栏显隐

    /// Dock 显隐：开关开启时**随主窗口联动**——窗口打开显示 Dock 图标、关闭即隐藏（纯后台）；
    /// 开关关闭时永不显示。
    /// 只在「窗口不存在」的时机切换策略（窗口存在时切换会闪跳）：
    /// 启动/打开主窗口前切 .regular，主窗口关闭后切 .accessory。
    /// 打开主窗口前调用：窗口创建前先把策略切回 .regular（无窗口时切换不闪跳）
    func prepareForMainWindow() {
        NSApp.setActivationPolicy(.regular)
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.iconImage(connected: AppState.current?.isConnected ?? false)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        // 图标随连接状态变化
        iconObserver = AppState.current?.$isConnected.sink { [weak self] connected in
            self?.statusItem?.button?.image = Self.iconImage(connected: connected)
        }
    }

    /// 菜单栏图标（黑白线条正负形，template 自动适配明暗）：
    /// 未连接 = 圆角方轮廓 + V 线条（只有边框）；连接 = 底色填满 + V 镂空（负形）。
    private static func iconImage(connected: Bool) -> NSImage? {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current else {
            image.unlockFocus()
            return nil
        }

        let fullRect = NSRect(x: 0, y: 0, width: size, height: size)
        let corner = size * 0.225
        let fillPath = NSBezierPath(roundedRect: fullRect, xRadius: corner, yRadius: corner)

        // 描边路径内缩半个线宽：贴着图片边界描边会被裁掉一半（轮廓畸形 + 锯齿）
        let strokeWidth: CGFloat = 1.5
        let strokePath = NSBezierPath(
            roundedRect: fullRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
            xRadius: corner,
            yRadius: corner
        )

        // V 字形（与 App 图标同款几何）
        let inset = size * 0.30
        let v = NSBezierPath()
        v.move(to: NSPoint(x: inset, y: size * 0.34))
        v.line(to: NSPoint(x: size * 0.5, y: size - inset))
        v.line(to: NSPoint(x: size - inset, y: size * 0.34))
        v.lineWidth = size * 0.13
        v.lineCapStyle = .round
        v.lineJoinStyle = .round

        NSColor.black.setFill()
        NSColor.black.setStroke()
        if connected {
            fillPath.fill()
            // V 镂空：必须走 NSGraphicsContext 的合成操作（NSBezierPath 用 AppKit 合成，
            // 改 CG blendMode 无效），且描边颜色要**不透明**——destinationOut 按源 alpha 擦除
            ctx.compositingOperation = .destinationOut
            v.stroke()
            ctx.compositingOperation = .sourceOver
        } else {
            strokePath.lineWidth = strokeWidth
            strokePath.stroke()
            v.stroke()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - 菜单构建（每次打开时重建，保证状态新鲜）

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        guard let state = AppState.current else { return }
        menu.removeAllItems()

        // 打开主界面（最顶部）
        let openItem = NSMenuItem(title: "打开主界面", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        // 开/关代理
        let toggle = NSMenuItem(
            title: state.isConnected ? "关闭代理" : "开启代理",
            action: #selector(toggleConnection),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.image = NSImage(
            systemSymbolName: state.isConnected ? "power.circle.fill" : "power",
            accessibilityDescription: nil
        )
        menu.addItem(toggle)

        let reconnect = NSMenuItem(
            title: state.shouldReclaimSystemProxy ? "重新接管系统代理" : "重新连接",
            action: #selector(reconnect),
            keyEquivalent: ""
        )
        reconnect.target = self
        reconnect.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(reconnect)
        menu.addItem(.separator())

        // 模式（当前模式提示 + 单选勾选）
        let modeHeader = NSMenuItem(title: "当前模式：\(state.settings.mode.displayName)", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        for mode in ProxyMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = state.settings.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // 节点（当前节点置顶 + 前 10 个常用节点）
        if state.nodes.isEmpty {
            let empty = NSMenuItem(title: "暂无节点", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            if let selected = state.selectedNode {
                let current = NSMenuItem(title: "当前：\(selected.name)", action: nil, keyEquivalent: "")
                current.isEnabled = false
                menu.addItem(current)
            }
            for node in state.nodes.prefix(10) {
                let item = NSMenuItem(title: node.name, action: #selector(selectNode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = node.id.uuidString
                item.state = state.settings.selectedNodeID == node.id ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Veil", action: #selector(terminate), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleConnection() {
        Task { await AppState.current?.toggleConnection() }
    }

    @objc private func reconnect() {
        Task { await AppState.current?.reconnect() }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ProxyMode(rawValue: raw) else { return }
        AppState.current?.setMode(mode)
    }

    @objc private func selectNode(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else { return }
        AppState.current?.selectNode(id)
    }

    @objc private func openMainWindow() {
        prepareForMainWindow()   // 先切回 .regular（无窗口时不闪跳），再创建窗口
        openMainWindowAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func terminate() {
        NSApp.terminate(nil)
    }
}
