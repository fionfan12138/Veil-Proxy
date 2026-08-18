import SwiftUI

/// 首页（Overview）：V 状态视觉 → 状态文字 → 当前节点 → 连接按钮 → 模式 → 轻量状态信息
struct OverviewView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                BrandMark(size: 56, isActive: appState.isConnected)
                    .animation(.easeInOut(duration: 0.2), value: appState.isConnected)

                VStack(spacing: 7) {
                    Text(appState.isConnected ? "Connected" : "Not Connected")
                        .font(.system(size: 22, weight: .semibold))
                    Text(appState.selectedNode?.name ?? "未选择节点")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    if let detail = connectionDetail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                ConnectButton(isConnected: appState.isConnected) {
                    Task { await appState.toggleConnection() }
                }

                ModePillSelector(selection: modeBinding)

                SpeedChartSection(
                    samples: appState.speedHistory,
                    isEnabled: appState.settings.enableSpeedChart,
                    onToggle: { appState.setEnableSpeedChart($0) }
                )

                StatusInfoRow(
                    downSpeed: appState.isConnected ? appState.currentDownSpeed : nil,
                    upSpeed: appState.isConnected ? appState.currentUpSpeed : nil,
                    realtimeEnabled: appState.settings.enableSpeedChart
                )
            }
            .frame(maxWidth: 360)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { appState.settings.mode },
            set: { appState.setMode($0) }
        )
    }

    /// 只在非默认状态下显示连接状态详情（如「连接失败：…」）
    private var connectionDetail: String? {
        switch appState.statusMessage {
        case "未连接", "已连接": return nil
        default: return appState.statusMessage
        }
    }
}

/// 连接按钮：低调圆角主按钮；已连接时转为淡色「Disconnect」
private struct ConnectButton: View {
    let isConnected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isConnected ? "Disconnect" : "Connect")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isConnected ? Color.accentColor : .white)
                .padding(.horizontal, 38)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isConnected ? Color.accentColor.opacity(0.12) : Color.accentColor)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isConnected)
    }
}

/// 轻量 pill selector：规则 / 全局 / 直连（自定义，非系统 Segmented Picker）
private struct ModePillSelector: View {
    @Binding var selection: ProxyMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProxyMode.allCases, id: \.self) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(mode == selection ? .primary : .secondary)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(mode == selection ? Color.primary.opacity(0.09) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

/// 轻量状态信息：Download / Upload（实时关闭或未连接时置灰）
private struct StatusInfoRow: View {
    /// 下载 / 上传速率（字节/秒）；nil = 未连接（显示占位）
    let downSpeed: Double?
    let upSpeed: Double?
    /// 实时速率是否开启（关闭时数值置灰）
    let realtimeEnabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            stat(value: downSpeed.map { formatSpeed($0) } ?? "—",
                 label: "Download",
                 dimmed: !realtimeEnabled || downSpeed == nil)
            divider
            stat(value: upSpeed.map { formatSpeed($0) } ?? "—",
                 label: "Upload",
                 dimmed: !realtimeEnabled || upSpeed == nil)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 20)
    }

    private func stat(value: String, label: String, dimmed: Bool) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(dimmed ? .secondary : .primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

/// 速率格式化：字节/秒 → 「1.2 MB/s / 320 KB/s / 98 B/s」
private func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec >= 1024 * 1024 {
        return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
    }
    if bytesPerSec >= 1024 {
        return String(format: "%.0f KB/s", bytesPerSec / 1024)
    }
    return String(format: "%.0f B/s", bytesPerSec)
}

/// 首页实时速率区：曲线图 + 文字图例 + 实时开关。
/// 下载 = 蓝实线带面积、上传 = 绿细线：线宽/面积/图例构成非颜色编码，颜色不单独传义。
private struct SpeedChartSection: View {
    let samples: [SpeedSample]
    /// 实时速率开关（关闭即停止后台轮询）
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpeedChartView(samples: samples, isEnabled: isEnabled)
            HStack(spacing: 14) {
                legendMark(color: SpeedChartView.downColor(in: colorScheme), label: "下载")
                legendMark(color: SpeedChartView.upColor(in: colorScheme), label: "上传")
                Spacer()
                Toggle("实时", isOn: Binding(get: { isEnabled }, set: onToggle))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("关闭后停止速率轮询，降低后台占用")
            }
        }
    }

    private func legendMark(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 3)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// 实时速率曲线：TimelineView 逐帧渲染 + Canvas 手绘平滑双曲线 + 下载面积渐变。
/// 点按时间定位：最新点在右缘，旧点随时间连续向左滑出窗口（iOS 式平滑滚动，不跳步）。
/// 线色经 dataviz 脚本校验（浅色 #5B9BD5/#34C759、深色 #3987E5/#28A745，
/// 深色档为通过验证器的合规加深色，不走 App 全局 accent）。
private struct SpeedChartView: View {
    let samples: [SpeedSample]
    /// 实时速率是否开启（关闭时显示「已关闭」占位）
    let isEnabled: Bool
    @Environment(\.colorScheme) private var colorScheme
    /// 纵轴上限的指数平滑值：新峰值快速纳入、回落后缓慢收起，
    /// 避免流量一抖整条曲线逐帧重缩放（看起来「跳」）
    @State private var smoothedMax: Double = 1024
    /// 鼠标在图表内的位置；nil = 未悬停。只驱动本地图表交互，不影响采样任务。
    @State private var hoverLocation: CGPoint?

    /// 图表时间窗口（秒），与 AppState 60 点历史对应
    private static let windowSeconds: Double = 60
    /// 纵轴下限 1 KB/s，避免空闲时除零/曲线贴死
    private static let scaleFloor: Double = 1024

    static func downColor(in colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 57/255, green: 135/255, blue: 229/255)   // #3987E5
            : Color(red: 91/255, green: 155/255, blue: 213/255)   // #5B9BD5
    }

    static func upColor(in colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 40/255, green: 167/255, blue: 69/255)    // #28A745
            : Color(red: 52/255, green: 199/255, blue: 89/255)    // #34C759
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
            if samples.isEmpty {
                Text(isEnabled ? "连接后显示实时速率" : "实时速率已关闭")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .transition(.opacity)
            } else {
                // 资源优先：8fps 平滑滚动——60s 窗口滑动速度仅 ~6pt/s，每帧 ~0.75pt，
                // 视觉与 30fps 无差别、CPU 唤醒降到 1/4；无实际流量时暂停（全零平线静态渲染即可）
                TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: timelinePaused)) { timeline in
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            Canvas { context, size in
                                drawChart(in: &context, size: size, now: timeline.date)
                            }
                            if let location = hoverLocation,
                               let info = hoverInfo(at: location, size: proxy.size, now: timeline.date) {
                                hoverOverlay(info: info, size: proxy.size)
                            }
                        }
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let location):
                                hoverLocation = location
                            case .ended:
                                hoverLocation = nil
                            }
                        }
                    }
                    .onChange(of: timeline.date) { _ in
                        updateSmoothedMax(now: timeline.date)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(height: 110)
        // 占位 ⇄ 曲线交叉淡入淡出（0.5s），出现/消失都不突兀
        .animation(.easeInOut(duration: 0.5), value: samples.isEmpty)
        // 断开清空后重置纵轴平滑值
        .onChange(of: samples.isEmpty) { isEmpty in
            if isEmpty { smoothedMax = Self.scaleFloor }
        }
    }

    /// 是否暂停逐帧渲染：采样不足 2 个、全是零值、或最大速率低于 2KB/s（噪声地板，
    /// 后台心跳等微弱流量不值得让曲线跑 8fps）
    private var timelinePaused: Bool {
        if samples.count < 2 { return true }
        let maxValue = samples.map { max($0.downBytesPerSec, $0.upBytesPerSec) }.max() ?? 0
        return maxValue < 2048
    }

    /// 纵轴上限指数平滑：上升快（新峰值快速纳入）、回落慢（缓慢收起，避免曲线「呼吸」）
    private func updateSmoothedMax(now: Date) {
        let visible = samples.filter { now.timeIntervalSince($0.date) <= Self.windowSeconds }
        let target = max(visible.map { max($0.downBytesPerSec, $0.upBytesPerSec) }.max() ?? Self.scaleFloor, Self.scaleFloor)
        let k = target > smoothedMax ? 0.20 : 0.02
        smoothedMax += (target - smoothedMax) * k
    }

    private func drawChart(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let insetTop: CGFloat = 8
        let insetBottom: CGFloat = 4
        let plotHeight = size.height - insetTop - insetBottom

        // 窗口内的采样（时间越旧越靠左，超出窗口的滑出）
        let visible = samples.filter { now.timeIntervalSince($0.date) <= Self.windowSeconds }
        guard !visible.isEmpty else { return }
        // 纵轴用平滑后的上限，避免逐帧重缩放跳变
        let maxValue = smoothedMax

        func xPosition(_ date: Date) -> CGFloat {
            let elapsed = now.timeIntervalSince(date)
            return size.width * CGFloat(1 - elapsed / Self.windowSeconds)
        }
        func yPosition(_ value: Double) -> CGFloat {
            let clamped = min(max(value / maxValue, 0), 1)
            return insetTop + plotHeight * (1 - CGFloat(clamped))
        }

        drawScaleGuides(in: &context, size: size, maxValue: maxValue, yPosition: yPosition)

        // 采样每秒到达一次，但时间轴在两次采样之间仍持续左移：最新点会暂时离开右缘，
        // 60 个点也只覆盖 59 段间隔，首尾都会周期性露出空隙。绘制时把边界值保持到
        // 左右边缘，曲线始终连续覆盖整段时间窗，不需要提高采样或 Timeline 刷新频率。
        let downPoints = pinToHorizontalEdges(
            visible.map { CGPoint(x: xPosition($0.date), y: yPosition($0.downBytesPerSec)) },
            width: size.width
        )
        let upPoints = pinToHorizontalEdges(
            visible.map { CGPoint(x: xPosition($0.date), y: yPosition($0.upBytesPerSec)) },
            width: size.width
        )
        guard let firstDown = downPoints.first, let lastDown = downPoints.last else { return }

        // 下载面积：曲线闭合到基线，渐变向下渐隐
        var downArea = smoothPath(points: downPoints)
        downArea.addLine(to: CGPoint(x: lastDown.x, y: size.height - insetBottom))
        downArea.addLine(to: CGPoint(x: firstDown.x, y: size.height - insetBottom))
        downArea.closeSubpath()
        context.fill(downArea, with: .linearGradient(
            Gradient(colors: [SpeedChartView.downColor(in: colorScheme).opacity(0.22),
                              SpeedChartView.downColor(in: colorScheme).opacity(0.0)]),
            startPoint: CGPoint(x: 0, y: insetTop),
            endPoint: CGPoint(x: 0, y: size.height - insetBottom)
        ))

        // 上传细线（1.5pt 无面积）+ 下载主线（2pt 带面积）
        context.stroke(smoothPath(points: upPoints), with: .color(SpeedChartView.upColor(in: colorScheme)), lineWidth: 1.5)
        context.stroke(smoothPath(points: downPoints), with: .color(SpeedChartView.downColor(in: colorScheme)), lineWidth: 2)

        // 基线
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - insetBottom))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - insetBottom))
        context.stroke(baseline, with: .color(Color.secondary.opacity(0.15)), lineWidth: 1)
    }

    /// 两条低对比度动态标尺（纵轴上限 / 一半），默认提供量级参照但不抢曲线视觉。
    private func drawScaleGuides(
        in context: inout GraphicsContext,
        size: CGSize,
        maxValue: Double,
        yPosition: (Double) -> CGFloat
    ) {
        for ratio in [1.0, 0.5] {
            let value = maxValue * ratio
            let y = yPosition(value)
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y))
            guide.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                guide,
                with: .color(Color.secondary.opacity(0.10)),
                style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])
            )

            let label = Text(formatSpeed(value))
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(Color.secondary.opacity(0.62))
            context.draw(
                label,
                at: CGPoint(x: size.width - 4, y: y + 2),
                anchor: .topTrailing
            )
        }
    }

    private struct HoverInfo {
        let x: CGFloat
        let downY: CGFloat
        let upY: CGFloat
        let ageText: String
        let downSpeed: Double
        let upSpeed: Double
    }

    /// 取鼠标横向位置最近的真实采样点，并映射到与 Canvas 完全相同的坐标系。
    private func hoverInfo(at location: CGPoint, size: CGSize, now: Date) -> HoverInfo? {
        let visible = samples.filter { now.timeIntervalSince($0.date) <= Self.windowSeconds }
        guard !visible.isEmpty else { return nil }
        let plotHeight = size.height - 8 - 4

        func xPosition(_ date: Date) -> CGFloat {
            let elapsed = now.timeIntervalSince(date)
            return min(max(size.width * CGFloat(1 - elapsed / Self.windowSeconds), 0), size.width)
        }
        guard let sample = visible.min(by: {
            abs(xPosition($0.date) - location.x) < abs(xPosition($1.date) - location.x)
        }) else { return nil }

        func yPosition(_ value: Double) -> CGFloat {
            let clamped = min(max(value / smoothedMax, 0), 1)
            return 8 + plotHeight * (1 - CGFloat(clamped))
        }
        let age = max(0, Int(now.timeIntervalSince(sample.date).rounded()))
        return HoverInfo(
            x: xPosition(sample.date),
            downY: yPosition(sample.downBytesPerSec),
            upY: yPosition(sample.upBytesPerSec),
            ageText: age == 0 ? "现在" : "\(age) 秒前",
            downSpeed: sample.downBytesPerSec,
            upSpeed: sample.upBytesPerSec
        )
    }

    /// 悬停竖线、双曲线采样点和浮层。鼠标离开即消失，不占用后台资源。
    private func hoverOverlay(info: HoverInfo, size: CGSize) -> some View {
        let tooltipWidth: CGFloat = 122
        let tooltipInset: CGFloat = 8
        // 浮层放到光标所在半区的对侧，避免盖住竖线和采样点：
        // 指向右半边时显示在左侧，指向左半边时显示在右侧。
        let tooltipCenterX = info.x >= size.width / 2
            ? tooltipInset + tooltipWidth / 2
            : size.width - tooltipInset - tooltipWidth / 2
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 1, height: max(0, size.height - 12))
                .offset(x: info.x - 0.5, y: 8)

            Circle()
                .fill(Self.downColor(in: colorScheme))
                .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                .frame(width: 7, height: 7)
                .position(x: info.x, y: info.downY)

            Circle()
                .fill(Self.upColor(in: colorScheme))
                .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                .frame(width: 7, height: 7)
                .position(x: info.x, y: info.upY)

            SpeedChartTooltip(
                ageText: info.ageText,
                downSpeed: info.downSpeed,
                upSpeed: info.upSpeed,
                downColor: Self.downColor(in: colorScheme),
                upColor: Self.upColor(in: colorScheme)
            )
            .frame(width: tooltipWidth)
            .position(x: tooltipCenterX, y: 30)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// 用首尾采样值补齐绘图区边界。右侧保持最新值直到下一次采样到达，
    /// 左侧保持最老可见值直到它滑出窗口，避免曲线两端出现周期性断口。
    private func pinToHorizontalEdges(_ points: [CGPoint], width: CGFloat) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        var result = points.map { point in
            CGPoint(x: min(max(point.x, 0), width), y: point.y)
        }

        if let first = result.first {
            if first.x > 0.5 {
                result.insert(CGPoint(x: 0, y: first.y), at: 0)
            } else {
                result[0].x = 0
            }
        }
        if let last = result.last {
            if last.x < width - 0.5 {
                result.append(CGPoint(x: width, y: last.y))
            } else {
                result[result.count - 1].x = width
            }
        }
        return result
    }

    /// 中点平滑折线：相邻点以二次贝塞尔经中点过渡，形成平滑曲线。
    /// 0 点返回空路径、1 点只画起点（连接后头一两秒只有 1 个采样，不能构造 1..<0 的空范围）
    private func smoothPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count >= 2 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(
                x: (points[i].x + points[i + 1].x) / 2,
                y: (points[i].y + points[i + 1].y) / 2
            )
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// 曲线悬停信息：紧凑显示采样时间、下载和上传速率。
private struct SpeedChartTooltip: View {
    let ageText: String
    let downSpeed: Double
    let upSpeed: Double
    let downColor: Color
    let upColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ageText)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            valueRow(color: downColor, label: "下载", value: formatSpeed(downSpeed))
            valueRow(color: upColor, label: "上传", value: formatSpeed(upSpeed))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 4, y: 2)
    }

    private func valueRow(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .foregroundColor(.primary)
        }
        .font(.system(size: 9, weight: .medium))
    }
}
