import SwiftUI
import AppKit

/// 访问日志页（3.6）：实时连接列表——目标、规则、经哪个节点、上下行字节、连接状态。
/// 数据来自 AppState 每秒轮询 GET /connections 合并的历史（活跃 + 最近断开，最新在前）。
struct LogsView: View {
    @EnvironmentObject private var appState: AppState
    /// 选中的日志行 id。选中高亮完全自绘（不用原生 List selection）——
    /// 原生列表的选中边框由 AppKit 绘制，列表每秒更新时边框会跟选中底色块脱节偏移
    @State private var selectedLogID: ConnectionInfo.ID?
    /// 右键/左键事件监听（右键冻结日志刷新，让 contextMenu 能稳定展开子菜单）
    @State private var rightClickMonitor: Any?
    @State private var leftClickMonitor: Any?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header(proxy)
                Divider()
                if !appState.isConnected {
                    emptyState
                } else if appState.connectionLogs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        // 用 VStack 而非 LazyVStack：懒加载栈在滚动后更新数据时可能不刷新可见区
                        VStack(spacing: 0) {
                            ForEach(appState.connectionLogs) { log in
                                LogRow(info: log)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(selectedLogID == log.id
                                                ? Color.accentColor.opacity(0.14) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedLogID = log.id }
                                    .contextMenu {
                                        Button("复制链接") {
                                            let text = log.host.isEmpty ? log.destination : log.host
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(text, forType: .string)
                                            appState.showToast("已复制「\(text)」")
                                        }
                                        Divider()
                                        Menu("添加到规则") {
                                            Button("走代理") { appState.addLogRule(from: log, action: .proxy) }
                                            Button("直连") { appState.addLogRule(from: log, action: .direct) }
                                            Button("拒绝") { appState.addLogRule(from: log, action: .reject) }
                                        }
                                    }
                            }
                        }
                        .padding(10)
                    }
                }
            }
        }
        .onAppear(perform: installMenuMonitors)
        .onDisappear(perform: removeMenuMonitors)
    }

    /// 刷新按钮与 ⌘R 共用：立即拉取合并 + 滚动到底部最新
    private func refreshAndScroll(_ proxy: ScrollViewProxy) {
        Task {
            await appState.refreshConnectionLogsNow()
            if let lastID = appState.connectionLogs.last?.id {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    /// 右键按下 → 冻结日志刷新（SwiftUI contextMenu 会随底层视图更新而关闭，
    /// 冻结后菜单与「添加到规则」子菜单都能稳定使用）；左键按下 → 恢复刷新
    private func installMenuMonitors() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            if event.window === NSApp.keyWindow {
                appState.pauseRealtimeUI()
            }
            return event
        }
        leftClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            appState.resumeRealtimeUI()
            return event
        }
    }

    private func removeMenuMonitors() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
        if let monitor = leftClickMonitor {
            NSEvent.removeMonitor(monitor)
            leftClickMonitor = nil
        }
        appState.resumeRealtimeUI()
    }

    private func header(_ proxy: ScrollViewProxy) -> some View {
        HStack {
            Text("日志").font(.title2.bold())
            Spacer()
            // 实时开关：关闭即停止日志轮询（设置页开关与此同步）
            Toggle("实时", isOn: logsBinding)
                .toggleStyle(.checkbox)
                .help("关闭后停止日志轮询，降低后台占用")
            Text(appState.isConnected ? "\(appState.connectionLogs.count) 条连接" : "未连接")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                refreshAndScroll(proxy)
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("立即刷新并跳到底部最新（⌘R）")
            .disabled(!appState.isConnected)
            // ⌘R = 刷新日志并跳到底部（仅日志页可见时生效；隐藏按钮注册快捷键）
            .background(
                Button("") { refreshAndScroll(proxy) }
                    .keyboardShortcut("r", modifiers: .command)
                    .hidden()
            )
            Button {
                appState.clearConnectionLogs()
            } label: {
                Label("清除", systemImage: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("清空日志")
            .disabled(appState.connectionLogs.isEmpty)
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(emptyTitle)
                .font(.title3.weight(.medium))
            if appState.isConnected && appState.settings.enableConnectionLogs {
                Text("打开网页后这里会显示每条连接的走向")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !appState.settings.enableConnectionLogs { return "访问日志已关闭" }
        return appState.isConnected ? "暂无连接" : "连接代理后显示实时连接"
    }

    private var logsBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.enableConnectionLogs },
            set: { appState.setEnableConnectionLogs($0) }
        )
    }
}

/// 单条连接行：状态点 + 目标/规则/链路 + 上下行字节 + 状态
private struct LogRow: View {
    let info: ConnectionInfo

    var body: some View {
        HStack(spacing: 10) {
            // 状态分级：已拒绝=红、活跃=绿、已断开=灰
            Circle()
                .fill(info.chains.contains("REJECT") ? Color.red : (info.isClosed ? Color.secondary.opacity(0.4) : Color.green))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.host.isEmpty ? info.destination : info.host)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(info.destination) · 规则 \(info.rule.isEmpty ? "—" : info.rule) · 经 \(chainText)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("↑\(formatBytes(info.upload)) ↓\(formatBytes(info.download))")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Text(statusText)
                    .font(.caption2)
                    .foregroundColor(info.chains.contains("REJECT") ? .red : (info.isClosed ? .secondary : .green))
            }
        }
        .padding(.vertical, 3)
        .opacity(info.isClosed ? 0.55 : 1)
    }

    private var chainText: String {
        info.chains.isEmpty ? "直连" : info.chains.joined(separator: " → ")
    }

    /// 状态文字：被拒显示「已拒绝（×N）」、断开显示「已断开」、活跃显示协议
    private var statusText: String {
        if info.chains.contains("REJECT") {
            return info.rejectCount > 1 ? "已拒绝 ×\(info.rejectCount)" : "已拒绝"
        }
        return info.isClosed ? "已断开" : info.network.uppercased()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1048576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}
