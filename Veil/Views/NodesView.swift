import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// 节点页：搜索 + 两列节点卡片（卡片底部内嵌该订阅剩余流量）+ 切换节点右下角提示
struct NodesView: View {
    @EnvironmentObject private var appState: AppState
    /// 分组过滤器的选中项（nil = 全部）
    @State private var selectedSubscriptionID: UUID?
    /// 当前正在拖拽排序的节点卡片（nil = 未在拖拽）
    @State private var draggedNode: ProxyNode?

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    /// 按选中的订阅分组过滤节点；nil = 全部
    private var filteredNodes: [ProxyNode] {
        guard let groupID = selectedSubscriptionID else { return appState.nodes }
        return appState.nodes.filter { $0.subscriptionID == groupID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.nodes.isEmpty {
                emptyState
            } else if filteredNodes.isEmpty {
                groupEmptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredNodes) { node in
                            nodeCard(node)
                        }
                    }
                    .padding(20)
                    // 排序变化时卡片弹簧滑位（iOS 图标重排的手感）
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: appState.nodes)
                }
            }
        }
        // ⌘R = 全部测速（仅节点页可见时生效；按钮隐藏，快捷键由 SwiftUI 全局注册）
        .background(
            Button("") { Task { await appState.testAllNodes() } }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        )
        // 兜底放置区：松手在卡片之间的空隙/页头等任意位置也能结束拖拽（归位 + 落盘），
        // 否则只有落在某张卡片正上方才会触发归位，卡片会卡在「空槽」状态像消失了一样
        .onDrop(of: [UTType.text], delegate: NodesPageDropDelegate(
            draggedNode: $draggedNode,
            onDropFinished: { appState.persistNodeOrder() }
        ))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("节点").font(.title2.bold())
            Spacer()
            // 全部测速：测速中显示进度图标并禁点，避免重复触发
            Button {
                Task { await appState.testAllNodes() }
            } label: {
                if appState.isTestingAllNodes {
                    ActivityIndicator()
                } else {
                    Image(systemName: "wifi")
                }
            }
            .buttonStyle(.borderless)
            .help("全部测速")
            .disabled(appState.isTestingAllNodes)
            // 分组过滤器（下拉菜单）：订阅数量多时只占当前选项宽度，不会挤爆头部
            Picker("分组", selection: $selectedSubscriptionID) {
                Text("全部").tag(Optional<UUID>.none)
                ForEach(appState.subscriptions) { subscription in
                    Text(subscription.name).tag(Optional(subscription.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(20)
    }

    /// 单个节点卡片：整卡可点切换节点（用 onTapGesture，避免外层 Button 与内层测速按钮嵌套冲突，
    /// 否则 macOS 上内层按钮点击会被外层吞掉，测速/切换都失灵）；右上测速按钮单独触发测速。
    private func nodeCard(_ node: ProxyNode) -> some View {
        let isSelected = appState.settings.selectedNodeID == node.id
        let isDragging = draggedNode?.id == node.id
        return VStack(alignment: .leading, spacing: 8) {
            NodeRow(
                node: node,
                delay: appState.nodeDelays[node.id],
                onTest: { Task { await appState.testNode(node) } },
                onRefresh: refreshAction(for: node),
                isRefreshing: isRefreshing(node),
                tagColor: subscription(for: node).map { SubscriptionColor.color(for: $0.colorHex) }
            )
            Divider()
            trafficFooter(for: node)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 拖拽中：原位卡片淡化成「空槽」。
        // 开始拖拽时弹簧淡出（withAnimation 在 onDrag 里触发）；放下时无动画立即归位——
        // 跟手预览同一时刻消失，若空槽还要渐入会出现「卡一下」的断层。
        .opacity(isDragging ? 0.25 : 1)
        .scaleEffect(isDragging ? 0.96 : 1)
        .onTapGesture {
            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                draggedNode = nil
            }
            appState.selectNode(node.id)
        }
        .onDrag {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                draggedNode = node
            }
            return NSItemProvider(object: node.id.uuidString as NSString)
        } preview: {
            dragPreview(for: node)
        }
        .onDrop(of: [UTType.text], delegate: NodeCardDropDelegate(
            target: node,
            draggedNode: $draggedNode,
            onReorder: { dragged, target in
                appState.moveNode(dragged, adjacentTo: target)
            },
            onDropFinished: {
                appState.persistNodeOrder()
            }
        ))
        .help("拖动卡片可调整顺序")
        .contextMenu {
            Button("测速") { Task { await appState.testNode(node) } }
            Button("删除", role: .destructive) { appState.deleteNode(node) }
        }
    }

    /// 拖拽跟手预览：完整复刻节点卡片（含流量脚注），随光标移动。
    /// 配合原位卡片淡化成空槽，实现「整卡被拿起 → 放下归位」的手感。
    private func dragPreview(for node: ProxyNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(node.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Spacer()
                ProtocolBadge(type: node.type)
                if let delay = appState.nodeDelays[node.id] {
                    Text("\(delay)ms")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            trafficFooter(for: node)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 12, y: 6)
    }

    /// 卡片底部流量区：有配额 → 剩余进度条；无配额 → 「无限流量」。
    /// 固定「文本行 + 进度条」两行结构，保证所有卡片等高、不割裂。
    @ViewBuilder
    private func trafficFooter(for node: ProxyNode) -> some View {
        let sub = subscription(for: node)
        let name = sub?.name ?? "节点"
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let remaining = sub?.remainingBytes, let total = sub?.totalBytes {
                    Text("剩余 \(bytesText(remaining)) / 共 \(bytesText(total))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("无限流量")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            TrafficBar(fraction: sub?.remainingFraction)
        }
    }

    private func subscription(for node: ProxyNode) -> Subscription? {
        guard let id = node.subscriptionID else { return nil }
        return appState.subscriptions.first(where: { $0.id == id })
    }

    /// 刷新该节点所属订阅的流量配额（无归属返回 nil，不显示刷新按钮）
    private func refreshAction(for node: ProxyNode) -> (() -> Void)? {
        guard let sub = subscription(for: node) else { return nil }
        return { Task { await appState.refreshSubscription(sub) } }
    }

    /// 该节点所属订阅是否正在刷新（刷新按钮转圈）
    private func isRefreshing(_ node: ProxyNode) -> Bool {
        guard let id = node.subscriptionID else { return false }
        return appState.refreshingSubscriptionIDs.contains(id)
    }

    /// 切换节点后的右下角提示（已上移到 ContentView 全局层，见 toastMessage）

    /// 流量单位换算（二进制）：1 KB = 1024 B、1 MB = 1024²、1 GB = 1024³、1 TB = 1024⁴。
    /// 机场配额以字节返回，后台「1000 GB」= 1000×1024³ 字节；若用 1000 进制会被误显示成 1.07 TB。
    private func bytesText(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let formatted = value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return "\(formatted) \(units[index])"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("暂无节点").font(.title3.weight(.medium))
            Text("添加订阅并解析后，节点会显示在这里")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 选中分组下没有节点（如订阅刚删除）时的兜底提示
    private var groupEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("该分组暂无节点").font(.title3.weight(.medium))
            Text("切换到「全部」查看所有节点")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 节点卡片拖拽排序代理：悬停到目标卡片即把拖拽的卡片移到其旁边（dropEntered 连调实现实时排序）
private struct NodeCardDropDelegate: DropDelegate {
    let target: ProxyNode
    @Binding var draggedNode: ProxyNode?
    let onReorder: (ProxyNode, ProxyNode) -> Void
    let onDropFinished: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedNode, dragged.id != target.id else { return }
        onReorder(dragged, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // 快速回弹归位（0.15s：既有「放下的落地感」，又不会出现预览消失后的断层）；顺序只在放下时落盘一次
        withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
            draggedNode = nil
        }
        onDropFinished()
        return true
    }
}

/// 纯 SwiftUI 转圈指示器（替代 AppKit ProgressView 转圈）。
/// AppKit 进度控件在按钮 label / 拖拽预览渲染等上下文里会被钉死 min==max 的尺寸提案，
/// 触发「NSAppKitProgressView max length 不满足 min<=max」警告；自绘实现从根上规避。
private struct ActivityIndicator: View {
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isRotating)
            .frame(width: 13, height: 13)
            .onAppear { isRotating = true }
    }
}

/// 纯 SwiftUI 流量进度条（替代 AppKit ProgressView 线性条）。
/// 有配额：轨道 + accent 填充（占比）；nil = 无限流量：满格中性色。
private struct TrafficBar: View {
    /// 剩余占比 0~1；nil = 无限流量
    let fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                if let fraction = fraction {
                    let clamped = min(1, max(0, fraction))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(clamped))
                } else {
                    Capsule().fill(Color.secondary.opacity(0.5))
                }
            }
        }
        .frame(height: 5)
    }
}

/// 整页兜底放置代理：松手落在卡片之间的空隙/页头等处时结束拖拽（不换位，只归位 + 落盘）
private struct NodesPageDropDelegate: DropDelegate {
    @Binding var draggedNode: ProxyNode?
    let onDropFinished: () -> Void

    func dropEntered(info: DropInfo) {}

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
            draggedNode = nil
        }
        onDropFinished()
        return true
    }
}
