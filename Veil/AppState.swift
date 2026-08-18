import Foundation
import Combine
import AppKit
import ServiceManagement

/// 一次速率采样（字节/秒，约 1 秒一个点；date 供曲线按时间平滑滚动定位）
struct SpeedSample: Equatable {
    let downBytesPerSec: Double
    let upBytesPerSec: Double
    let date: Date
}

/// 全局共享状态：节点 / 订阅 / 设置 / 连接状态，视图通过 @EnvironmentObject 读写。
/// 负责「状态 + 持久化 + 内核启停 + 订阅拉取」的粘合；系统代理、测速、模式经 API 即时生效等在后续步骤接入。
@MainActor
final class AppState: ObservableObject {
    /// 全局唯一实例（AppDelegate 等 AppKit 侧从中取状态；创建顺序无关）
    static weak var current: AppState?

    // MARK: - 数据
    @Published var nodes: [ProxyNode] = []
    @Published var subscriptions: [Subscription] = []
    @Published var settings: AppSettings
    @Published var sidebarSelection: SidebarSection? = .home

    // MARK: - 连接状态
    @Published var isConnected = false
    @Published var statusMessage = "未连接"
    /// 订阅拉取结果 / 错误（订阅页顶部展示）
    @Published var subscriptionStatus: String?
    /// 是否正在全部更新订阅（「全部更新」按钮禁点用，防重入）
    @Published var isRefreshingAllSubscriptions = false
    /// 正在刷新流量配额的订阅 ID 集合（节点卡片刷新按钮转圈用）
    @Published var refreshingSubscriptionIDs: Set<UUID> = []
    /// 节点延迟（key = 节点 id，值 = 毫秒；测速失败则无该项）
    @Published var nodeDelays: [UUID: Int] = [:]
    /// 是否正在全部测速（节点页 WiFi 图标转进度、禁点，防重复触发）
    @Published var isTestingAllNodes = false
    /// 右下角全局提示文案（切节点 / 端口生效等；nil = 不显示）
    @Published var toastMessage: String?

    // MARK: - 实时速率

    /// 速率历史（最近 60 个采样，1 秒一个），首页曲线图用
    @Published var speedHistory: [SpeedSample] = []
    /// 当前下载 / 上传速率（字节/秒）
    @Published var currentDownSpeed: Double = 0
    @Published var currentUpSpeed: Double = 0

    /// 速率历史长度（秒）
    static let speedHistoryLimit = 60
    private var speedPollTask: Task<Void, Never>?
    private var lastTrafficCounters: (up: Int64, down: Int64)?
    private var lastSampleDate: Date?
    /// 主窗口关闭后只保留代理核心，暂停所有仅服务于界面的实时采集。
    private var isMainWindowVisible = false

    // MARK: - 访问日志（3.6）

    /// 访问日志（活跃 + 最近断开的连接，最新在前）
    @Published var connectionLogs: [ConnectionInfo] = []
    /// 日志保留条数上限
    static let connectionLogLimit = 200
    private var connectionsPollTask: Task<Void, Never>?
    /// 内核日志增量读取偏移（解析 REJECT 记录用；连接时内核日志被截断，随之为 0）
    private var coreLogReadOffset: UInt64 = 0
    /// 实时 UI 更新暂停标志：右键菜单打开期间冻结所有 @Published 刷新——
    /// @EnvironmentObject 订阅整个 AppState，任何属性每秒变化都会让整棵视图树重算、
    /// SwiftUI 的 contextMenu 随即被关闭。菜单打开期间速率/日志的 UI 写入全部暂停
    /// （内部累计计数器照常维护，恢复后补一个大采样）。
    private var realtimeUpdatesPaused = false
    private var realtimePauseResumeTask: Task<Void, Never>?

    private let core: CoreManager
    /// 本次会话 Veil 是否成功开过系统代理（退出时仅在该情况下还原，避免误关其它软件的代理）
    private var proxyEnabledByUs = false
    private let persistence = Persistence.shared
    private let subscriptionService = SubscriptionService()
    private let systemProxy = SystemProxyManager.shared

    init() {
        let loadedSettings = persistence.loadSettings()
        settings = loadedSettings
        // 控制器端口必须与 ConfigBuilder 写进 config.yaml 的一致（都用 settings.controllerPort），
        // 不能各自硬编码 9090，否则用户改端口后 API 请求打错地方
        core = CoreManager(controllerPort: loadedSettings.controllerPort)
        nodes = persistence.loadNodes()
        subscriptions = persistence.loadSubscriptions()

        // 正常退出：立即还原系统代理 + 停内核（硬性要求「退出后不影响 Mac 正常上网」）。
        // 退出时 async 来不及完成，用同步 shutdownSync() 阻塞式还原。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdownSync()
            }
        }

        // 启动自检（步骤 3.2）：进程被强杀后系统代理可能仍指向本应用端口，
        // 本次启动内核必然未运行 → 自动清除遗留代理，保证不影响正常上网
        Task {
            if systemProxy.pointsToProxy(port: settings.mixedPort) {
                await systemProxy.disable()
            }
        }

        // 订阅自动更新定时器（设置开启时生效）
        restartAutoRefreshTimer()

        // 应用保存的外观（上次选了浅色/深色时，本次启动同步到 NSApp）
        applyAppearance()

        // 最后注册全局引用（所有存储属性初始化完成后才能暴露 self）
        Self.current = self
    }

    // MARK: - 当前节点 / 模式

    var selectedNode: ProxyNode? {
        guard let id = settings.selectedNodeID else { return nil }
        return nodes.first { $0.id == id }
    }

    func selectNode(_ id: UUID?) {
        let previous = settings.selectedNodeID
        settings.selectedNodeID = id
        persistSettings()
        // 切到「另一个」节点时右下角给个提示；取消选中 / 重复点同一个节点不提示
        if let id = id, id != previous, let node = nodes.first(where: { $0.id == id }) {
            showToast("已切换到「\(node.name)」")
        }
        // 连接中切节点：经控制接口把 select 组切到新节点，即时生效，无需重启内核
        guard isConnected, let node = selectedNode else { return }
        Task { await self.applyNodeSelection(node) }
    }

    /// 右下角短暂提示（纯 UI，2 秒自动消失，不阻塞）
    func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            toastMessage = nil
        }
    }

    /// 连接中经 API 把 select 组切到指定节点，即时生效。
    /// mihomo 在 rule 模式流量走我们自己的 PROXY 组、global 模式走内建 GLOBAL 组；
    /// 两个组都切一遍，确保无论当前模式如何都能切过去（不存在的组切换失败忽略）。
    private func applyNodeSelection(_ node: ProxyNode) async {
        do {
            try await core.apiClient.switchProxy(group: ConfigBuilder.selectorGroupName, to: node.name)
        } catch {
            statusMessage = "切换节点失败：\(error.localizedDescription)"
            print("[switchProxy] 切 PROXY 组失败：\(error)")
            return
        }
        try? await core.apiClient.switchProxy(group: "GLOBAL", to: node.name)
        // 断开所有活动连接：已建立的连接不会随 select 组自动迁到新节点，
        // 不断开的话浏览器 keep-alive 等旧连接继续走旧节点，「切换」看起来不生效。
        do {
            try await core.apiClient.closeAllConnections()
        } catch {
            print("[switchProxy] 断开旧连接失败：\(error)")
        }
        let now = await core.apiClient.currentSelection(group: ConfigBuilder.selectorGroupName)
        print("[switchProxy] 已切换到「\(node.name)」，PROXY.now=「\(now ?? "nil")」")
    }

    // MARK: - 实时速率轮询

    /// 连接成功后打开 /traffic 持续流（每秒一个 JSON 快照），用两次累计值之差计算速率采样；
    /// 流中断（如内核重启）1 秒后自动重连，直到任务被取消。
    private func startSpeedPolling() {
        speedPollTask?.cancel()
        lastTrafficCounters = nil
        lastSampleDate = nil
        // 用整窗零值铺底：曲线从连接起就占满整幅宽度（底部平线），新数据从右缘滚入、
        // 整体向左平滑滚动——而不是从右缘一个点一个点「长出来」
        speedHistory = Self.zeroSeedHistory()
        currentDownSpeed = 0
        currentUpSpeed = 0
        speedPollTask = Task { [weak self] in
            guard let self else { return }
            var retryDelay: UInt64 = 1_000_000_000   // 失败重试退避：1s → 2s → 4s … 封顶 15s
            while !Task.isCancelled {
                // 未连接 / 内核进程已死（崩溃、被强杀）时停止轮询，不再空打控制器
                guard self.isConnected, self.core.isProcessAlive else { break }
                do {
                    try await self.readSpeedStream()
                    // 流正常结束（罕见）：等 1s 再重连，避免热循环
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    retryDelay = 1_000_000_000
                } catch {
                    // 失败退避：避免 Connection refused 每秒刷屏、持续增加 CPU 唤醒
                    try? await Task.sleep(nanoseconds: retryDelay)
                    retryDelay = min(retryDelay * 2, 15_000_000_000)
                }
                guard !Task.isCancelled else { break }
            }
        }
    }

    /// 整窗零值采样（-59s … now，每秒一个），供连接时给曲线铺底
    private static func zeroSeedHistory() -> [SpeedSample] {
        let now = Date()
        return (0..<speedHistoryLimit).map { i in
            SpeedSample(
                downBytesPerSec: 0,
                upBytesPerSec: 0,
                date: now.addingTimeInterval(Double(i - speedHistoryLimit) + 1)
            )
        }
    }

    /// 读取 /traffic 流直到中断：逐行解析 JSON 快照，更新当前速率与历史
    private func readSpeedStream() async throws {
        let bytes = try await core.apiClient.openTrafficStream()
        // 退出（含任务被取消）时主动断开流，避免后台连接残留
        defer { bytes.task.cancel() }
        for try await line in bytes.lines {
            guard !Task.isCancelled else { return }
            guard let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let upTotal = (json["upTotal"] as? NSNumber)?.int64Value,
                  let downTotal = (json["downTotal"] as? NSNumber)?.int64Value else { continue }
            let sampleDate = Date()
            if let last = lastTrafficCounters, let lastDate = lastSampleDate {
                // 流里每行的 up/down 是「距上一行」的增量，累计值在 upTotal/downTotal；
                // 必须用累计值之差 ÷ 实际间隔 = 真实速率（用 up/down 再求差 = 增量的增量，
                // 会正负振荡被 clamp 成 0，曲线变成一座座山峰）
                let elapsed = sampleDate.timeIntervalSince(lastDate)
                // 右键菜单冻结期间不写 @Published（避免视图树重算关闭菜单）；
                // lastTrafficCounters 照常更新，恢复后下一个采样自然覆盖整个暂停区间
                if elapsed > 0, !realtimeUpdatesPaused {
                    // 内核重启会重置累计计数器，负增量按 0 处理
                    currentDownSpeed = max(0, Double(downTotal - last.down) / elapsed)
                    currentUpSpeed = max(0, Double(upTotal - last.up) / elapsed)
                    speedHistory.append(SpeedSample(
                        downBytesPerSec: currentDownSpeed,
                        upBytesPerSec: currentUpSpeed,
                        date: sampleDate
                    ))
                    if speedHistory.count > Self.speedHistoryLimit {
                        speedHistory.removeFirst(speedHistory.count - Self.speedHistoryLimit)
                    }
                }
            }
            lastTrafficCounters = (upTotal, downTotal)
            lastSampleDate = sampleDate
        }
    }

    /// 等内核控制接口就绪：先等 0.5s（mihomo 从进程拉起（exec）到绑定 9090 只需几十毫秒），
    /// 再每 0.5s ping 一次、最多 ~5 秒——先等再 ping，避免首请求抢跑必吃一次 Connection refused。
    /// 内核绑定失败时会自行退出 → terminationHandler 置 isProcessAlive=false，
    /// 后续轮询的存活检查会立即停止，不会空打控制器。
    private func waitForCoreReady() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        for _ in 0..<10 {
            if await core.apiClient.ping() { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// 连接后每秒轮询 /connections 更新访问日志（3.6）；失败指数退避，与速率轮询同款存活检查
    private func startConnectionsPolling(resetCoreLogOffset: Bool = true) {
        connectionsPollTask?.cancel()
        if resetCoreLogOffset {
            coreLogReadOffset = 0
        }
        // 不清空历史：重连（如规则修改的自动重连）后新连接叠加在既有条目之上
        connectionsPollTask = Task { [weak self] in
            guard let self else { return }
            var retryDelay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                guard self.isConnected, self.core.isProcessAlive else { break }
                if self.realtimeUpdatesPaused {
                    // 右键菜单打开期间冻结更新（轻睡，避免空转）
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                do {
                    let current = try await self.core.apiClient.connections()
                    // 被 REJECT 的连接不会出现在 /connections（匹配即拒绝、瞬间关闭），
                    // 从内核日志增量解析「using REJECT」行补进访问日志
                    let inc = self.core.readLogIncrement(from: self.coreLogReadOffset)
                    self.coreLogReadOffset = inc.newOffset
                    let rejects = Self.parseRejectLines(inc.text)
                    // 同一域名 5 秒内的重复拒绝折叠成一条（浏览器被拒后会反复重试，否则刷屏）
                    let freshRejects = Self.foldRecentRejects(rejects, into: &self.connectionLogs)
                    self.mergeConnectionLogs(current + freshRejects)
                    // 1 秒一轮（要实时就开开关、要省电就关，不做降频）
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    retryDelay = 1_000_000_000
                } catch {
                    try? await Task.sleep(nanoseconds: retryDelay)
                    retryDelay = min(retryDelay * 2, 15_000_000_000)
                }
                guard !Task.isCancelled else { break }
            }
        }
    }

    /// 把 5 秒内同域名的重复拒绝折叠进既有条目（计数 +1、刷新时间），返回仍需新增的条目
    private static func foldRecentRejects(
        _ rejects: [ConnectionInfo],
        into logs: inout [ConnectionInfo]
    ) -> [ConnectionInfo] {
        let now = Date()
        var fresh: [ConnectionInfo] = []
        for reject in rejects {
            if let index = logs.firstIndex(where: {
                $0.chains.contains("REJECT")
                    && $0.host == reject.host
                    && now.timeIntervalSince($0.start) < 5
            }) {
                logs[index].rejectCount += 1
                logs[index].start = reject.start
            } else {
                fresh.append(reject)
            }
        }
        return fresh
    }

    /// 解析内核日志里的 REJECT 匹配行（如
    /// `[TCP] 127.0.0.1:53342 --> www.youtube.com:443 match DomainSuffix(youtube.com) using REJECT`）
    /// → 生成「已拒绝」的日志条目（REJECT 的连接不进入 /connections，只能从日志补）
    private static func parseRejectLines(_ text: String) -> [ConnectionInfo] {
        var result: [ConnectionInfo] = []
        for line in text.components(separatedBy: "\n") {
            guard line.contains("using REJECT"),
                  let arrow = line.range(of: "--> "),
                  let matchRange = line.range(of: " match ") else { continue }
            let targetPart = String(line[arrow.upperBound..<matchRange.lowerBound])   // 如 www.youtube.com:443
            let host = targetPart.components(separatedBy: ":").dropLast().joined(separator: ":")
            guard !host.isEmpty else { continue }
            let rulePart = String(line[matchRange.upperBound...])
            let rule = rulePart.replacingOccurrences(of: " using REJECT", with: "")
            result.append(ConnectionInfo(
                id: "reject-\(UUID().uuidString)",
                host: host,
                destination: targetPart,
                source: "",
                network: line.contains("[UDP]") ? "udp" : "tcp",
                rule: rule,
                chains: ["REJECT"],
                upload: 0,
                download: 0,
                start: Date(),
                isClosed: true
            ))
        }
        return result
    }

    private func stopConnectionsPolling() {
        connectionsPollTask?.cancel()
        connectionsPollTask = nil
        // 保留历史：把仍显示活跃的全部标记为已断开（不再清空，用户可在日志页手动清空）
        connectionLogs = connectionLogs.map { entry in
            var closed = entry
            closed.isClosed = true
            return closed
        }
    }

    /// 窗口关闭时只暂停采集，不修改连接状态和日志内容，也不重置增量读取位置。
    private func pauseConnectionsPolling() {
        connectionsPollTask?.cancel()
        connectionsPollTask = nil
    }

    /// 清空访问日志
    func clearConnectionLogs() {
        connectionLogs = []
    }

    /// 立即拉取一次连接列表并合并（日志页「刷新」按钮；常规由每秒轮询自动完成）
    func refreshConnectionLogsNow() async {
        guard isConnected else { return }
        do {
            let current = try await core.apiClient.connections()
            mergeConnectionLogs(current)
        } catch {
            showToast("刷新失败：\(error.localizedDescription)")
        }
    }

    /// 暂停实时 UI 刷新（右键菜单打开时调用）；30 秒兜底自动恢复
    func pauseRealtimeUI() {
        realtimeUpdatesPaused = true
        realtimePauseResumeTask?.cancel()
        realtimePauseResumeTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            resumeRealtimeUI()
        }
    }

    /// 恢复实时 UI 刷新（左键点击等交互时调用）
    func resumeRealtimeUI() {
        realtimeUpdatesPaused = false
        realtimePauseResumeTask?.cancel()
        realtimePauseResumeTask = nil
    }

    /// 主窗口生命周期：关闭后暂停 UI 专用轮询，重新出现时按持久化设置恢复。
    func setMainWindowVisible(_ visible: Bool) {
        guard isMainWindowVisible != visible else { return }
        isMainWindowVisible = visible

        if visible {
            guard isConnected, core.isProcessAlive else { return }
            if settings.enableSpeedChart { startSpeedPolling() }
            if settings.enableConnectionLogs {
                startConnectionsPolling(resetCoreLogOffset: false)
            }
        } else {
            // 关闭过程中不再需要右键菜单的短暂停顿兜底任务。
            resumeRealtimeUI()
            stopSpeedPolling()
            pauseConnectionsPolling()
        }
    }

    /// 合并新一批连接：更新已存在、追加新出现、消失的标记为已断开。
    /// **最新在底部（日志追加式）**：已有行的位置永不改变——列表不会因新条目插入而
    /// 整列位移，右键菜单/选中/滚动都不会被「挤」。
    private func mergeConnectionLogs(_ current: [ConnectionInfo]) {
        var merged = current
        let activeIDs = Set(merged.map(\.id))
        for old in connectionLogs where !activeIDs.contains(old.id) {
            var closed = old
            closed.isClosed = true
            merged.append(closed)
        }
        merged.sort { $0.start < $1.start }   // 升序：最新在底部
        if merged.count > Self.connectionLogLimit {
            merged.removeFirst(merged.count - Self.connectionLogLimit)   // 裁剪最旧（顶部）
        }
        connectionLogs = merged
    }

    /// 停止轮询并清空速率数据（断开 / 退出时调用）
    private func stopSpeedPolling() {
        speedPollTask?.cancel()
        speedPollTask = nil
        lastTrafficCounters = nil
        speedHistory = []
        currentDownSpeed = 0
        currentUpSpeed = 0
    }

    // MARK: - 测速

    /// 单节点测速：TCP 直连节点「主机:端口」测时延（ping），失败写 nil（界面显示 WiFi 图标）
    func testNode(_ node: ProxyNode) async {
        nodeDelays[node.id] = await LatencyProbe.tcpLatency(host: node.server, port: node.port)
    }

    /// 全部节点测速：并发发起 TCP 直连 ping，结果逐项写入 nodeDelays（测完一个显示一个）。
    /// 连接在后台线程并发进行（LatencyProbe 内部 detached），UI 写入经 MainActor 串行。
    func testAllNodes() async {
        guard !isTestingAllNodes else { return }
        isTestingAllNodes = true
        await withTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask { await self.testNode(node) }
            }
        }
        isTestingAllNodes = false
    }

    /// 删除单个节点（本地列表移除；若删的是当前选中节点，则一并清空选中）
    func deleteNode(_ node: ProxyNode) {
        nodes.removeAll { $0.id == node.id }
        if settings.selectedNodeID == node.id {
            settings.selectedNodeID = nil
            persistSettings()
        }
        try? persistence.saveNodes(nodes)
    }

    /// 拖拽排序：把 dragged 移到 target 旁边——从前面拖来插到 target 之后、从后面拖来插到 target 之前。
    /// 必须用「移除前」的下标比较拖来的方向，否则相邻卡片（如 A 拖到 B 上想往后挪一位）
    /// 会在移除后下标重合、被当成「插到前面」而无变化。
    /// 悬停即生效（dropEntered 连调）；这里不写盘，顺序在放下时由 persistNodeOrder() 落盘。
    func moveNode(_ dragged: ProxyNode, adjacentTo target: ProxyNode) {
        guard dragged.id != target.id else { return }
        guard let fromIdx = nodes.firstIndex(where: { $0.id == dragged.id }),
              let origTargetIdx = nodes.firstIndex(where: { $0.id == target.id }) else { return }
        var reordered = nodes
        reordered.remove(at: fromIdx)
        // 移除后目标的新下标
        let targetIdx = origTargetIdx > fromIdx ? origTargetIdx - 1 : origTargetIdx
        let insertIdx = fromIdx < origTargetIdx ? targetIdx + 1 : targetIdx
        reordered.insert(dragged, at: insertIdx)
        nodes = reordered
    }

    /// 拖拽排序落盘：仅放下时调用（排序过程中不写盘，避免拖拽中磁盘 I/O 造成卡顿）
    func persistNodeOrder() {
        try? persistence.saveNodes(nodes)
    }

    /// 本次连接实际使用的系统代理端口（nil = 未连接）；用于判断端口是否真的变了
    private var runningMixedPort: Int?

    /// 订阅自动更新定时器：启动后 60 秒先刷一次，之后按设置间隔定时刷新全部订阅。
    /// 开关/间隔变化时由 setter 重启本定时器。
    private var autoRefreshTask: Task<Void, Never>?

    func restartAutoRefreshTimer() {
        autoRefreshTask?.cancel()
        guard settings.autoRefreshSubscriptions else { return }
        let intervalHours = settings.autoRefreshIntervalHours
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            // 启动后延迟 60 秒先刷新一次，避免刚启动就占资源
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            while !Task.isCancelled {
                guard !Task.isCancelled else { break }
                await self.refreshAllSubscriptions()
                try? await Task.sleep(nanoseconds: UInt64(intervalHours) * 3_600_000_000_000)
            }
        }
    }

    /// 开关订阅自动更新
    func setAutoRefreshSubscriptions(_ enabled: Bool) {
        settings.autoRefreshSubscriptions = enabled
        persistSettings()
        restartAutoRefreshTimer()
    }

    /// 设置自动更新间隔（小时）
    func setAutoRefreshInterval(_ hours: Int) {
        settings.autoRefreshIntervalHours = hours
        persistSettings()
        restartAutoRefreshTimer()
    }

    /// 修改系统代理端口（仅保存输入；生效由输入框按回车触发 commitPorts）
    func updateMixedPort(_ port: Int) {
        settings.mixedPort = port
        persistSettings()
    }

    /// 修改控制接口端口（同上）
    func updateControllerPort(_ port: Int) {
        settings.controllerPort = port
        persistSettings()
    }

    /// 端口输入确认（回车或点击输入框外触发）：钳制校验 → 与运行中值比较 → 需要时自动重连应用。
    /// announce = true 时所有结果都弹提示（回车）；false 时仅「真的生效了」才弹（点击空白静默提交）。
    func commitPorts(announce: Bool = true) {
        let clampedMixed = min(max(settings.mixedPort, 1024), 65535)
        let clampedController = min(max(settings.controllerPort, 1024), 65535)
        if clampedMixed != settings.mixedPort || clampedController != settings.controllerPort {
            settings.mixedPort = clampedMixed
            settings.controllerPort = clampedController
            persistSettings()
            if announce { showToast("端口需在 1024–65535 之间，已自动调整") }
        }
        guard isConnected else {
            if announce { showToast("端口已保存，连接时生效") }
            return
        }
        guard settings.mixedPort != runningMixedPort || settings.controllerPort != core.controllerPort else {
            if announce { showToast("端口未变化") }
            return
        }
        Task {
            await stopConnection()
            guard !Task.isCancelled else { return }
            await startConnection()
            showToast("端口已生效")
        }
    }

    /// 切换代理模式：持久化 + 连接中经 PATCH /configs 即时生效（步骤 2.2）；
    /// 未连接时下次连接由 ConfigBuilder 写入新 mode 生效。
    /// 添加自定义分流规则（步骤 3.5）：目标非空且不含逗号（mihomo 规则分隔符）。
    /// 同目标（域名+匹配方式 / IP）已有规则时更新其动作而不是重复添加。
    func addCustomRule(domain: String, isSuffix: Bool, action: CustomRule.Action, isIP: Bool = false) {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(",") else { return }
        if let index = settings.customRules.firstIndex(where: {
            $0.domain == trimmed && $0.isSuffix == isSuffix && $0.isIP == isIP
        }) {
            settings.customRules[index].action = action
            persistSettings()
            showToast("规则已更新：\(trimmed) → \(action.displayName)")
            reconnectAfterRuleChange()
            return
        }
        settings.customRules.append(CustomRule(domain: trimmed, isSuffix: isSuffix, action: action, isIP: isIP))
        persistSettings()
        showToast("已添加规则：\(trimmed) → \(action.displayName)")
        reconnectAfterRuleChange()
    }

    /// 从访问日志一键添加规则（3.6）：域名连接生成「含子域名」规则，纯 IP 连接生成 IP-CIDR 规则。
    /// 域名会剥掉 www./m. 前缀——否则生成 DOMAIN-SUFFIX,www.youtube.com 会漏掉裸域名
    /// youtube.com（实测裸域名绕过规则走 PROXY）。
    func addLogRule(from info: ConnectionInfo, action: CustomRule.Action) {
        if info.host.isEmpty {
            // 从「IP:端口」里取出纯 IP（兼容 [IPv6]:端口 与 IPv4:端口）
            let dest = info.destination
            let ip: String
            if dest.hasPrefix("[") {
                ip = String(dest.dropFirst().prefix { $0 != "]" })
            } else if let lastColon = dest.lastIndex(of: ":") {
                ip = String(dest[..<lastColon])
            } else {
                ip = dest
            }
            guard !ip.isEmpty else { return }
            addCustomRule(domain: ip, isSuffix: false, action: action, isIP: true)
        } else {
            let normalized = ["www.", "m."].first { info.host.hasPrefix($0) }
                .map { String(info.host.dropFirst($0.count)) } ?? info.host
            addCustomRule(domain: normalized, isSuffix: true, action: action)
        }
    }

    /// 切换到下一个 / 上一个节点（⌘↑/⌘↓ 快捷键用，按 nodes 顺序循环；无节点或单节点不动作）
    func cycleNode(forward: Bool) {
        guard nodes.count > 1 else { return }
        let currentIndex: Int
        if let id = settings.selectedNodeID,
           let index = nodes.firstIndex(where: { $0.id == id }) {
            currentIndex = index
        } else {
            // 未选中过：前进从第一个开始，后退从最后一个开始
            currentIndex = forward ? -1 : nodes.count
        }
        let nextIndex = forward
            ? (currentIndex + 1) % nodes.count
            : (currentIndex - 1 + nodes.count) % nodes.count
        selectNode(nodes[nextIndex].id)
    }

    /// 当前内核版本（运行中走 API，未连接读二进制 -v）
    func kernelVersion() async -> String? {
        await core.kernelVersion()
    }

    /// 检查内核更新：返回 (当前版本, GitHub 最新版本)
    func checkKernelUpdate() async throws -> (current: String?, latest: String) {
        async let current = core.kernelVersion()
        async let latest = core.latestKernelVersion()
        return (await current, try await latest)
    }

    /// 下载并安装新内核；完成后若在连接中自动重连以使用新内核
    func updateKernel(to version: String) async {
        do {
            showToast("正在下载内核 \(version)…")
            try await core.installKernel(version: version)
            showToast("内核已更新到 \(version)")
            if isConnected {
                reconnectAfterRuleChange()   // 复用自动重连：下次启动即用新内核
            }
        } catch {
            showToast("内核更新失败：\(error.localizedDescription)")
        }
    }

    /// 设置界面外观（跟随系统/浅色/深色，即时生效）
    func setAppearance(_ appearance: AppAppearance) {
        settings.appearance = appearance
        persistSettings()
        applyAppearance()
    }

    /// 设置局域网共享（开/关后自动重连生效）
    func setAllowLAN(_ enabled: Bool) {
        settings.allowLAN = enabled
        persistSettings()
        reconnectAfterRuleChange()
    }

    /// 保存局域网认证用户名（输入过程只保存）
    func setLANUsername(_ value: String) {
        settings.lanUsername = value
        persistSettings()
    }

    /// 保存局域网认证密码（输入过程只保存）
    func setLANPassword(_ value: String) {
        settings.lanPassword = value
        persistSettings()
    }

    /// 局域网认证修改后重连生效（输入框按回车触发）
    func applyLANAuth() {
        showToast("局域网设置已应用")
        if isConnected {
            reconnectAfterRuleChange()
        }
    }

    /// 设置开机自启（SMAppService.mainApp 登录项注册/注销）
    func setAutoLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.autoLaunchAtLogin = enabled
            persistSettings()
            showToast(enabled ? "已开启开机自启" : "已关闭开机自启")
        } catch {
            showToast("设置开机自启失败：\(error.localizedDescription)")
        }
    }

    /// 实时速率开关（关闭即停轮询清数据；连接中开启则立即开始）
    func setEnableSpeedChart(_ enabled: Bool) {
        settings.enableSpeedChart = enabled
        persistSettings()
        if enabled {
            if isConnected, isMainWindowVisible { startSpeedPolling() }
        } else {
            stopSpeedPolling()
        }
    }

    /// 访问日志开关（同上）
    func setEnableConnectionLogs(_ enabled: Bool) {
        settings.enableConnectionLogs = enabled
        persistSettings()
        if enabled {
            if isConnected, isMainWindowVisible { startConnectionsPolling() }
        } else {
            stopConnectionsPolling()
        }
    }


    /// 应用外观到 NSApp。只做两件安全的事：
    /// ① NSApp.appearance（AppKit 全局外观，标题栏/毛玻璃等随之切换）；
    /// ② 标记各窗口内容视图重绘（不动焦点、不改窗口 appearance 属性——
    ///    之前的失焦-聚焦循环导致红绿灯等标题栏元素失绘）。
    private func applyAppearance() {
        let target: NSAppearance?
        switch settings.appearance {
        case .system: target = nil
        case .light: target = NSAppearance(named: .aqua)
        case .dark: target = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = target
        for window in NSApp.windows {
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
        }
    }

    /// 设置订阅标签颜色（nil = 恢复默认蓝；纯界面标识，不影响配置与连接）
    func setSubscriptionColor(_ subscription: Subscription, hex: String?) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].colorHex = hex
        persistSubscriptions()
    }

    /// 修改已有规则的执行动作（走代理/直连/拒绝）
    func updateCustomRule(_ rule: CustomRule, action: CustomRule.Action) {
        guard let index = settings.customRules.firstIndex(where: { $0.id == rule.id }) else { return }
        guard settings.customRules[index].action != action else { return }
        settings.customRules[index].action = action
        persistSettings()
        reconnectAfterRuleChange()
    }

    /// 删除自定义分流规则
    func removeCustomRule(_ rule: CustomRule) {
        settings.customRules.removeAll { $0.id == rule.id }
        persistSettings()
        reconnectAfterRuleChange()
    }

    private var reconnectTask: Task<Void, Never>?

    /// 规则变更后自动断连重连一次，让新规则立即生效（无需手动重连）。
    /// 未连接时不动作（下次连接自然带上新规则）。
    private func reconnectAfterRuleChange() {
        guard isConnected else { return }
        reconnectTask?.cancel()
        reconnectTask = Task {
            await stopConnection()
            guard !Task.isCancelled else { return }
            await startConnection()
        }
    }

    func setMode(_ mode: ProxyMode) {
        guard mode != settings.mode else { return }
        settings.mode = mode
        persistSettings()
        guard isConnected else { return }
        Task {
            do {
                try await core.apiClient.setMode(mode)
                // 断开旧连接：已建立的连接不会随模式自动换路由（浏览器 keep-alive 等），
                // 不断开的话模式切换对旧连接不可见——与切节点同款处理
                try? await core.apiClient.closeAllConnections()
            } catch {
                statusMessage = "切换模式失败：\(error.localizedDescription)"
                print("[setMode] 失败：\(error)")
            }
        }
    }

    // MARK: - 连接开关（内核启停 + 配置生成）

    func toggleConnection() async {
        if isConnected {
            await stopConnection()
        } else {
            await startConnection()
        }
    }

    /// 菜单栏用于展示智能重连当前会执行的动作；读取系统当前有效代理，不启动检测进程。
    var shouldReclaimSystemProxy: Bool {
        guard isConnected, core.isProcessAlive else { return false }
        return !systemProxy.pointsToProxy(port: runningMixedPort ?? settings.mixedPort)
    }

    /// 智能重连：未连接/内核异常时启动或重启；仅系统代理被改写时直接重新接管，避免无谓重启内核。
    func reconnect() async {
        guard isConnected else {
            await startConnection()
            return
        }

        guard core.isProcessAlive else {
            await stopConnection()
            guard !Task.isCancelled else { return }
            await startConnection()
            return
        }

        let port = runningMixedPort ?? settings.mixedPort
        if !systemProxy.pointsToProxy(port: port) {
            statusMessage = "正在重新接管系统代理"
            do {
                try await systemProxy.enable(port: port)
                var reclaimed = false
                for attempt in 0..<5 {
                    if systemProxy.pointsToProxy(port: port) {
                        reclaimed = true
                        break
                    }
                    if attempt < 4 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                guard reclaimed else {
                    proxyEnabledByUs = false
                    statusMessage = "系统代理重新接管失败"
                    showToast("系统代理重新接管失败")
                    return
                }
                proxyEnabledByUs = true
                statusMessage = "已连接"
                showToast("已重新接管系统代理")
            } catch {
                proxyEnabledByUs = false
                statusMessage = "系统代理重新接管失败：\(error.localizedDescription)"
                showToast("系统代理重新接管失败")
            }
            return
        }

        await stopConnection()
        guard !Task.isCancelled else { return }
        await startConnection()
    }

    func startConnection() async {
        do {
            // 端口钳制到合法范围并同步给内核管理（连接时生效；输入过程中的非法值不影响运行）
            let clampedMixed = min(max(settings.mixedPort, 1024), 65535)
            let clampedController = min(max(settings.controllerPort, 1024), 65535)
            if clampedMixed != settings.mixedPort || clampedController != settings.controllerPort {
                settings.mixedPort = clampedMixed
                settings.controllerPort = clampedController
                persistSettings()
            }
            core.syncControllerPort(clampedController)
            let config = ConfigBuilder.build(nodes: nodes, settings: settings)
            try await core.start(config: config)
            runningMixedPort = clampedMixed
            coreLogReadOffset = 0   // CoreManager.start 会截断 mihomo 日志；即使窗口关闭也要同步重置
            isConnected = true
            statusMessage = "已连接"
            // 等内核控制接口就绪再开流量轮询：mihomo 进程刚拉起时 9090 还没监听，
            // 直接开流会先吃到 1-2 次 Connection refused
            await waitForCoreReady()
            if isMainWindowVisible, settings.enableSpeedChart { startSpeedPolling() }
            if isMainWindowVisible, settings.enableConnectionLogs {
                startConnectionsPolling(resetCoreLogOffset: false)
            }
            do {
                // 系统代理设置在后台线程执行（async），完成后回主线程更新状态，不阻塞 UI
                try await systemProxy.enable(port: settings.mixedPort)
                proxyEnabledByUs = true
            } catch {
                proxyEnabledByUs = false
                statusMessage = "已连接，但系统代理设置失败：\(error.localizedDescription)"
            }
        } catch {
            isConnected = false
            statusMessage = "连接失败：\(error.localizedDescription)"
        }
    }

    func stopConnection() async {
        stopSpeedPolling()
        stopConnectionsPolling()
        // 先还原系统代理，再停内核，避免出现「系统代理仍指向已停内核」的窗口
        await systemProxy.disable()
        proxyEnabledByUs = false
        core.stop()
        runningMixedPort = nil
        isConnected = false
        statusMessage = "未连接"
    }

    /// 退出前同步清理（阻塞当前线程，仅供 applicationWillTerminate 调用）。
    /// 正常交互路径请用异步的 stopConnection()。
    func shutdownSync() {
        stopSpeedPolling()
        stopConnectionsPolling()
        // 只还原 Veil 本次开过的代理——若本次从未开过（仅启动又退出），
        // 不触碰系统代理，避免误关 Clash Verge 等其它软件的代理状态（步骤 3.2）
        if proxyEnabledByUs {
            systemProxy.disableSync()
        }
        core.stop()
        isConnected = false
        statusMessage = "未连接"
    }

    // MARK: - 订阅增删 + 拉取

    @discardableResult
    func addSubscription(name: String, url: String) -> Subscription {
        let subscription = Subscription(name: name, url: url)
        subscriptions.append(subscription)
        persistSubscriptions()
        return subscription
    }

    func deleteSubscription(_ subscription: Subscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        persistSubscriptions()
        // 删除订阅时一并移除其节点（否则节点会变成无归属的孤儿）
        removeNodes(of: subscription.id)
    }

    func setSubscriptionEnabled(_ subscription: Subscription, enabled: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].enabled = enabled
        persistSubscriptions()
        if enabled {
            // 启用：立即拉取一次，节点回来
            Task { await refreshSubscription(subscriptions[index]) }
        } else {
            // 停用：从节点列表移除该订阅的节点（选中的一并清空）
            removeNodes(of: subscription.id)
        }
    }

    /// 移除某订阅的节点；若删的是当前选中节点，则清空选中（步骤 3.1）
    private func removeNodes(of subscriptionID: UUID) {
        let before = nodes.count
        nodes.removeAll { $0.subscriptionID == subscriptionID }
        guard nodes.count != before else { return }
        if let selected = settings.selectedNodeID, !nodes.contains(where: { $0.id == selected }) {
            settings.selectedNodeID = nil
            persistSettings()
        }
        try? persistence.saveNodes(nodes)
    }

    /// 拉取单个订阅并合并节点、更新流量配额；返回解析出的节点数
    private func refreshAndMerge(_ subscription: Subscription) async throws -> Int {
        let result = try await subscriptionService.fetch(from: subscription.url)
        // 给节点打上订阅归属，供节点页按订阅分组展示流量
        let tagged = result.nodes.map { node -> ProxyNode in
            var n = node
            n.subscriptionID = subscription.id
            return n
        }
        mergeNodes(tagged)
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index].updatedAt = Date()
            if let info = result.userInfo {
                subscriptions[index].totalBytes = info.totalBytes
                subscriptions[index].usedBytes = info.usedBytes
            }
            persistSubscriptions()
        }
        return result.nodes.count
    }

    /// 更新单个订阅（提示条显示结果 + 右下角弹窗反馈，节点页刷新流量时也能看到）
    func refreshSubscription(_ subscription: Subscription) async {
        refreshingSubscriptionIDs.insert(subscription.id)
        defer { refreshingSubscriptionIDs.remove(subscription.id) }
        do {
            let count = try await refreshAndMerge(subscription)
            subscriptionStatus = "「\(subscription.name)」已更新，解析出 \(count) 个节点"
            showToast("「\(subscription.name)」流量已更新")
        } catch {
            subscriptionStatus = "订阅更新失败：\(error.localizedDescription)"
            showToast("流量刷新失败：\(error.localizedDescription)")
        }
    }

    /// 全部订阅顺序更新（防重入），结果汇总到提示条
    func refreshAllSubscriptions() async {
        guard !isRefreshingAllSubscriptions else { return }
        isRefreshingAllSubscriptions = true
        defer { isRefreshingAllSubscriptions = false }

        var successCount = 0
        var failures: [String] = []
        for subscription in subscriptions {
            // 逐订阅标记刷新状态，订阅卡片/节点卡片的刷新按钮跟着转圈
            refreshingSubscriptionIDs.insert(subscription.id)
            do {
                _ = try await refreshAndMerge(subscription)
                successCount += 1
            } catch {
                failures.append("「\(subscription.name)」")
            }
            refreshingSubscriptionIDs.remove(subscription.id)
        }
        if failures.isEmpty {
            subscriptionStatus = "已更新全部 \(successCount) 个订阅"
        } else {
            subscriptionStatus = "更新完成：成功 \(successCount) 个，失败：\(failures.joined(separator: "、"))"
        }
    }

    // MARK: - 持久化

    /// 按 server:port 去重合并进现有节点；重复时补齐老数据缺失的订阅归属
    private func mergeNodes(_ incoming: [ProxyNode]) {
        var existing = nodes
        var indexByKey: [String: Int] = [:]
        for (i, node) in existing.enumerated() {
            indexByKey["\(node.server):\(node.port)"] = i
        }
        for node in incoming {
            let key = "\(node.server):\(node.port)"
            if let idx = indexByKey[key] {
                // 已存在：补齐订阅归属（老数据节点可能没有 subscriptionID）；
                // 名字同步为最新拉取的（机场会改节点名，如流量后缀变化），刷新后名字跟着更新
                if existing[idx].subscriptionID == nil, node.subscriptionID != nil {
                    existing[idx].subscriptionID = node.subscriptionID
                }
                existing[idx].name = node.name
            } else {
                indexByKey[key] = existing.count
                existing.append(node)
            }
        }
        nodes = existing
        try? persistence.saveNodes(nodes)
    }

    private func persistSettings() {
        try? persistence.saveSettings(settings)
    }

    private func persistSubscriptions() {
        try? persistence.saveSubscriptions(subscriptions)
    }
}
