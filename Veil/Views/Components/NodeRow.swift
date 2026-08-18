import SwiftUI

/// 协议徽标：小标签显示协议名
struct ProtocolBadge: View {
    let type: ProxyType

    var body: some View {
        Text(type.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.18))
            .foregroundColor(.accentColor)
            .cornerRadius(5)
    }
}

/// 节点行内容：名称 + 协议徽标 + 测速（WiFi 图标 → 延迟值）。
/// 「切换节点」由外层卡片整卡可点负责，这里只保留测速按钮（.borderless 拦截点击，不触发外层选择）。
struct NodeRow: View {
    let node: ProxyNode
    /// 测速延迟（毫秒）；nil = 未测或测速失败（显示 WiFi 图标）
    let delay: Int?
    let onTest: () -> Void
    /// 刷新该节点所属订阅的流量配额；nil = 无订阅归属，不显示刷新按钮
    var onRefresh: (() -> Void)? = nil
    /// 是否正在刷新该节点所属订阅（按钮转圈 + 禁点）
    var isRefreshing: Bool = false
    /// 所属订阅的标签颜色（nil = 无归属，不显示色点）
    var tagColor: Color? = nil

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                if let tagColor = tagColor {
                    ColorDot(color: tagColor, size: 9)
                }
                Text(node.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Spacer()
                ProtocolBadge(type: node.type)
            }
            Button(action: onTest) {
                delayLabel
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())   // 整个框都可点（borderless 按钮命中区常偏小于视觉）
            .help("测速")
            if let onRefresh = onRefresh {
                Button(action: onRefresh) {
                    // 刷新中图标旋转 + accent 色，让刷新「可感知」。
                    // 锚点下移到 0.56：arrow.clockwise 的箭头尖伸出在圆圈上方，
                    // 视觉圆心低于边界框中心，绕框中心转会明显「画圈晃动」
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(isRefreshing ? .accentColor : .secondary)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0), anchor: UnitPoint(x: 0.5, y: 0.56))
                        .animation(
                            isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                            value: isRefreshing
                        )
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("刷新流量")
                .disabled(isRefreshing)
            }
        }
    }

    /// 延迟位置：未测显示 WiFi 图标（点击测速），已测显示延迟值（点击重测）。
    /// 图标居中 + 56×24 命中区，解决 borderless 按钮「要往左偏才能点中」的偏移问题
    private var delayLabel: some View {
        Group {
            if let delay = delay {
                Text("\(delay)ms")
                    .foregroundColor(delayColor(delay))
            } else {
                Image(systemName: "wifi")
                    .foregroundColor(.accentColor)
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .frame(width: 56, height: 24, alignment: .center)
        .contentShape(Rectangle())
    }

    /// 延迟颜色：<300ms 绿、<1000ms 橙、其余红
    private func delayColor(_ delay: Int) -> Color {
        switch delay {
        case ..<300: return .green
        case ..<1000: return .orange
        default: return .red
        }
    }
}
