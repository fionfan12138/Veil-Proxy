import SwiftUI

/// 订阅页：卡片式订阅列表（两列网格，每卡显示节点数量）+ 可关闭的更新结果提示条
struct SubscriptionsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingAdd = false
    @State private var pendingDelete: Subscription?
    @State private var showingDeleteConfirm = false

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let status = appState.subscriptionStatus {
                statusBanner(status)
            }
            if appState.subscriptions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(appState.subscriptions) { subscription in
                            SubscriptionRow(
                                subscription: subscription,
                                nodeCount: nodeCount(for: subscription),
                                onToggleEnabled: { enabled in
                                    appState.setSubscriptionEnabled(subscription, enabled: enabled)
                                },
                                onUpdate: {
                                    Task { await appState.refreshSubscription(subscription) }
                                },
                                onDelete: {
                                    pendingDelete = subscription
                                    showingDeleteConfirm = true
                                },
                                isRefreshing: appState.refreshingSubscriptionIDs.contains(subscription.id)
                            )
                            .contextMenu {
                                // 右键设置标签颜色（当前项打勾；「默认」= 恢复默认蓝；色点预览）
                                Menu("标签颜色") {
                                    ForEach(SubscriptionColor.palette, id: \.name) { entry in
                                        Button {
                                            appState.setSubscriptionColor(subscription, hex: entry.hex)
                                        } label: {
                                            HStack(spacing: 8) {
                                                ColorDot(color: SubscriptionColor.color(for: entry.hex))
                                                Text(entry.name)
                                                if subscription.colorHex == entry.hex {
                                                    Image(systemName: "checkmark")
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        // ⌘R = 全部更新（仅订阅页可见时生效；隐藏按钮由 SwiftUI 全局注册快捷键）
        .background(
            Button("") { Task { await appState.refreshAllSubscriptions() } }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        )
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionSheet { name, url in
                let subscription = appState.addSubscription(name: name, url: url)
                Task { await appState.refreshSubscription(subscription) }
            }
        }
        .alert("删除订阅", isPresented: $showingDeleteConfirm, presenting: pendingDelete) { subscription in
            Button("删除", role: .destructive) {
                appState.deleteSubscription(subscription)
            }
            Button("取消", role: .cancel) {}
        } message: { subscription in
            Text("确定删除「\(subscription.name)」吗？此操作不可撤销。")
        }
    }

    private var header: some View {
        HStack {
            Text("订阅").font(.title2.bold())
            Spacer()
            // 自动更新开关 + 间隔
            Toggle("自动更新", isOn: autoRefreshBinding)
                .toggleStyle(.checkbox)
                .help("定时自动刷新全部订阅")
            Picker("", selection: intervalBinding) {
                ForEach([1, 2, 4, 6, 12, 24], id: \.self) { hours in
                    Text("每 \(hours) 小时").tag(hours)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!appState.settings.autoRefreshSubscriptions)
            Button {
                Task { await appState.refreshAllSubscriptions() }
            } label: {
                HStack(spacing: 4) {
                    // 全部更新期间图标旋转（只转图标不转文字）
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .rotationEffect(.degrees(appState.isRefreshingAllSubscriptions ? 360 : 0))
                        .animation(
                            appState.isRefreshingAllSubscriptions
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                            value: appState.isRefreshingAllSubscriptions
                        )
                    Text("全部更新")
                }
            }
            .disabled(appState.isRefreshingAllSubscriptions)
            Button {
                showingAdd = true
            } label: {
                Label("添加订阅", systemImage: "plus")
            }
        }
        .padding(20)
    }

    private var autoRefreshBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.autoRefreshSubscriptions },
            set: { appState.setAutoRefreshSubscriptions($0) }
        )
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { appState.settings.autoRefreshIntervalHours },
            set: { appState.setAutoRefreshInterval($0) }
        )
    }

    /// 该订阅解析出的节点数量
    private func nodeCount(for subscription: Subscription) -> Int {
        appState.nodes.filter { $0.subscriptionID == subscription.id }.count
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("暂无订阅").font(.title3.weight(.medium))
            Text("点击右上角「添加订阅」导入订阅链接")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 订阅拉取结果 / 错误提示条（带关闭按钮）
    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 13))
            Spacer(minLength: 0)
            Button {
                appState.subscriptionStatus = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("关闭提示")
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.06))
    }
}

/// 添加订阅的弹窗
private struct AddSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String, String) -> Void

    @State private var name = ""
    @State private var url = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加订阅").font(.headline)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("订阅链接（URL）", text: $url)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    onAdd(trimmedName, trimmedURL)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
