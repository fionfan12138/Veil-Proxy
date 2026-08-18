import SwiftUI
import AppKit

/// 设置页：端口 / 自定义规则 / 关于
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    // 端口输入框焦点（点空白结束编辑时用于静默提交）
    @FocusState private var mixedPortFocused: Bool
    @FocusState private var controllerPortFocused: Bool
    /// 点击输入框外结束编辑的事件监听（macOS 的 SwiftUI TextField 默认点击空白不失焦）
    @State private var clickMonitor: Any?

    // 自定义规则添加表单（步骤 3.5）
    @State private var newRuleDomain = ""
    @State private var newRuleSuffix = true
    @State private var newRuleAction: CustomRule.Action = .proxy

    var body: some View {
        Form {
            Section {
                LabeledContent("系统代理端口 (mixed-port)") {
                    TextField("", value: mixedPortBinding, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .focused($mixedPortFocused)
                        .onSubmit { appState.commitPorts() }
                }
                LabeledContent("控制接口端口") {
                    TextField("", value: controllerPortBinding, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .focused($controllerPortFocused)
                        .onSubmit { appState.commitPorts() }
                }
            } header: {
                Text("端口")
            }

            Section {
                ForEach(appState.settings.customRules) { rule in
                    HStack(spacing: 10) {
                        // 匹配方式移到悬停提示，行内不占宽度，域名不再被挤
                        Text(rule.domain)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(rule.isIP ? "匹配方式：IP 地址"
                                : (rule.isSuffix ? "匹配方式：含子域名" : "匹配方式：精确匹配"))
                        Spacer()
                        // 动作可直接修改：行内下拉菜单，改完自动重连生效
                        Picker("", selection: actionBinding(for: rule)) {
                            ForEach(CustomRule.Action.allCases, id: \.self) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        Button {
                            appState.removeCustomRule(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除规则")
                    }
                }
                // 添加表单分两行，避免单行塞不下
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        // Form 行里的 TextField 不给宽度会塌缩成 0 宽（不可输入），必须显式给 frame
                        TextField("域名", text: $newRuleDomain)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 200, maxWidth: .infinity)
                            .onSubmit(addRule)   // 回车 = 添加
                        Toggle("含子域名", isOn: $newRuleSuffix)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                    }
                    HStack(spacing: 8) {
                        Text("动作：").foregroundColor(.secondary)
                        Picker("", selection: $newRuleAction) {
                            ForEach(CustomRule.Action.allCases, id: \.self) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        Spacer()
                        Button("添加", action: addRule)
                            .disabled(newRuleDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("自定义规则")
                    Text("仅在「规则」模式下参与分流")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Picker("外观", selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("外观")
            }

            Section {
                Toggle("开机自启", isOn: autoLaunchBinding)
            } header: {
                Text("通用")
            }

            Section {
                Toggle("局域网共享", isOn: lanBinding)
                if appState.settings.allowLAN {
                    LabeledContent("本机地址") {
                        HStack(spacing: 6) {
                            Text(displayedIPHint).foregroundColor(.secondary)
                            Button(action: { refreshLocalIP(announce: true) }) {
                                // 点击后箭头旋转半圈（锚点 0.56：arrow.clockwise 箭头尖在圆圈上方，
                                // 视觉圆心低于边界框中心，绕框中心转会画圈晃动）
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                    .rotationEffect(.degrees(spinningIP ? 360 : 0), anchor: UnitPoint(x: 0.5, y: 0.56))
                                    .animation(spinningIP ? .easeOut(duration: 0.5) : .default, value: spinningIP)
                            }
                            .buttonStyle(.borderless)
                            .help("刷新本机 IP")
                        }
                    }
                    TextField("用户名（可选）", text: lanUsernameBinding)
                        .onSubmit { appState.applyLANAuth() }
                    SecureField("密码（可选）", text: lanPasswordBinding)
                        .onSubmit { appState.applyLANAuth() }
                }
            } header: {
                Text("局域网共享")
            }

            Section {
                Toggle("实时速率（首页曲线）", isOn: speedChartBinding)
                Toggle("访问日志", isOn: logsBinding)
            } header: {
                Text("实时数据")
            }

            Section("关于") {
                LabeledContent("版本") {
                    Text(appVersion).foregroundColor(.secondary)
                }
                LabeledContent("内核") {
                    HStack(spacing: 8) {
                        Text(kernelVersionText).foregroundColor(.secondary)
                        Button("检查更新") { checkUpdate() }
                            .buttonStyle(.borderless)
                            .disabled(isChecking)
                        if let latest = latestVersion, isNewer(latest, than: kernelVersionText) {
                            Button("更新到 \(latest)") { updateKernel(to: latest) }
                                .buttonStyle(.borderless)
                                .disabled(isUpdating)
                        }
                    }
                }
                if isUpdating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在下载更新内核…").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            installClickMonitor()
            // 首次进入读取当前内核版本与本机 IP
            if kernelVersionText == "读取中…" {
                Task { kernelVersionText = await appState.kernelVersion() ?? "未知（未连接）" }
            }
            refreshLocalIP(announce: false)
        }
        .onDisappear(perform: removeClickMonitor)
        .onChange(of: mixedPortFocused) { _ in commitIfDoneEditing() }
        .onChange(of: controllerPortFocused) { _ in commitIfDoneEditing() }
    }

    /// 两个端口输入框都失焦时按回车同款逻辑静默确认（无变化不弹提示）
    private func commitIfDoneEditing() {
        guard !mixedPortFocused && !controllerPortFocused else { return }
        appState.commitPorts(announce: false)
    }

    /// 监听左键点击：命中目标（含父链）不是文本输入控件时结束编辑（失焦）
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            if let window = event.window, window === NSApp.keyWindow {
                let view = window.contentView?.hitTest(event.locationInWindow)
                if !Self.isTextInput(view) {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    /// 命中视图（含父链）是否为文本输入控件（NSTextField / NSTextView）
    private static func isTextInput(_ view: NSView?) -> Bool {
        var current = view
        while let v = current {
            if v is NSTextField || v is NSTextView { return true }
            current = v.superview
        }
        return false
    }

    /// 添加自定义规则（按钮与回车共用）；成功后清空输入，规则立即出现在上方列表
    private func addRule() {
        appState.addCustomRule(domain: newRuleDomain, isSuffix: newRuleSuffix, action: newRuleAction)
        newRuleDomain = ""
    }

    /// 单条规则的动作绑定：改完持久化并自动重连
    private func actionBinding(for rule: CustomRule) -> Binding<CustomRule.Action> {
        Binding(
            get: {
                appState.settings.customRules.first(where: { $0.id == rule.id })?.action ?? .proxy
            },
            set: { newAction in
                appState.updateCustomRule(rule, action: newAction)
            }
        )
    }

    private var lanBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.allowLAN },
            set: { appState.setAllowLAN($0) }
        )
    }

    private var lanUsernameBinding: Binding<String> {
        Binding(
            get: { appState.settings.lanUsername },
            set: { appState.setLANUsername($0) }
        )
    }

    private var lanPasswordBinding: Binding<String> {
        Binding(
            get: { appState.settings.lanPassword },
            set: { appState.setLANPassword($0) }
        )
    }

    /// 本机地址展示值（点刷新按钮才更新，不后台自动刷新）
    @State private var displayedIPHint = "本机IP:7890"
    /// 刷新按钮旋转动画状态
    @State private var spinningIP = false

    /// 刷新本机 IP：announce = true（点按钮）才转圈 + 弹提示；进页面自动刷新保持静默
    private func refreshLocalIP(announce: Bool) {
        displayedIPHint = localIPHint
        guard announce else { return }
        spinningIP = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            spinningIP = false
        }
        appState.showToast("本机 IP 已刷新")
    }

    /// 局域网代理地址提示：http://<本机IP>:<端口>
    private var localIPHint: String {
        let ip = localIPAddress ?? "本机IP"
        return "\(ip):\(appState.settings.mixedPort)"
    }

    /// 本机局域网 IPv4 地址（取第一个 192./10./172. 网段接口；无则 nil）
    private var localIPAddress: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        // 用 sequence 遍历链表（ifa_next 为 Optional，遇到 nil 自然终止）
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = interface.pointee
            let name = String(cString: iface.ifa_name)
            let family = iface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), name != "lo0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip.hasPrefix("192.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                    address = ip
                    break
                }
            }
        }
        return address
    }

    private var autoLaunchBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.autoLaunchAtLogin },
            set: { appState.setAutoLaunchAtLogin($0) }
        )
    }

    private var speedChartBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.enableSpeedChart },
            set: { appState.setEnableSpeedChart($0) }
        )
    }

    private var logsBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.enableConnectionLogs },
            set: { appState.setEnableConnectionLogs($0) }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { appState.settings.appearance },
            set: { appState.setAppearance($0) }
        )
    }

    private var mixedPortBinding: Binding<Int> {
        Binding(
            get: { appState.settings.mixedPort },
            set: { appState.updateMixedPort($0) }
        )
    }

    private var controllerPortBinding: Binding<Int> {
        Binding(
            get: { appState.settings.controllerPort },
            set: { appState.updateControllerPort($0) }
        )
    }

    // 内核版本检查状态（阶段 3.8）
    @State private var kernelVersionText = "读取中…"
    @State private var latestVersion: String?
    @State private var isChecking = false
    @State private var isUpdating = false

    private func checkUpdate() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let result = try await appState.checkKernelUpdate()
                kernelVersionText = result.current ?? "未知（未连接）"
                latestVersion = result.latest
                if isNewer(result.latest, than: result.current) {
                    appState.showToast("发现新内核：\(result.latest)")
                } else {
                    appState.showToast("已是最新版本")
                }
            } catch {
                appState.showToast("检查更新失败：\(error.localizedDescription)")
            }
        }
    }

    private func updateKernel(to version: String) {
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            await appState.updateKernel(to: version)
            isUpdating = false
            kernelVersionText = version
            latestVersion = nil
        }
    }

    /// 版本号比较（v1.19.29 vs v1.20.1）
    private func isNewer(_ latest: String, than current: String?) -> Bool {
        guard let current = current else { return true }
        let a = latest.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
        let b = current.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    private var appVersion: String {
        guard let info = Bundle.main.infoDictionary,
              let version = info["CFBundleShortVersionString"] as? String else {
            return "1.0"
        }
        return version
    }
}
