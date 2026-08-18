import SwiftUI

/// 订阅标签颜色：预设色板 + 解析（nil = 默认蓝 accent）。
/// 订阅卡片与节点卡片共用；未设置的订阅显示默认蓝。
enum SubscriptionColor {
    static let palette: [(name: String, hex: String?)] = [
        ("默认", nil),
        ("红色", "#E05252"),
        ("橙色", "#E8933B"),
        ("黄色", "#D9B24C"),
        ("绿色", "#4CAF50"),
        ("青色", "#2AA8A0"),
        ("紫色", "#8E7CC3"),
        ("粉色", "#D9769C"),
        ("灰色", "#8A8F98"),
    ]

    static func color(for hex: String?) -> Color {
        guard let hex = hex else { return .accentColor }
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let rgb = Int(cleaned, radix: 16) else { return .accentColor }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

/// 标签颜色小圆点（订阅卡片名字旁 / 节点卡片名字前）
struct ColorDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// 订阅卡片：名称 + 启用开关 + 节点数量 + 更新时间 + 更新/删除操作。
/// 与节点页卡片同款视觉（圆角、浅底色、细描边），保证两页观感一致。
struct SubscriptionRow: View {
    let subscription: Subscription
    /// 该订阅下的节点数量（由外层从 AppState 统计传入）
    let nodeCount: Int
    let onToggleEnabled: (Bool) -> Void
    let onUpdate: () -> Void
    let onDelete: () -> Void
    /// 是否正在更新该订阅（更新按钮转圈 + 禁点）
    var isRefreshing: Bool = false

    var body: some View {
        let tagColor = SubscriptionColor.color(for: subscription.colorHex)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ColorDot(color: tagColor, size: 11)
                Text(subscription.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Toggle("", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                // 节点数量徽标：用标签颜色着色（未设置 = 默认蓝 accent）
                Text("\(nodeCount) 个节点")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tagColor.opacity(0.18))
                    .foregroundColor(tagColor)
                    .cornerRadius(5)
                Spacer()
                Text(updatedText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack(spacing: 2) {
                Button(action: onUpdate) {
                    HStack(spacing: 4) {
                        // 更新中图标旋转（锚点 0.56：箭头尖伸出在圆圈上方，视觉圆心低于框中心）
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(isRefreshing ? .accentColor : .secondary)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0), anchor: UnitPoint(x: 0.5, y: 0.56))
                            .animation(
                                isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                value: isRefreshing
                            )
                        Text("更新")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("更新订阅")
                .disabled(isRefreshing)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("删除订阅")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { subscription.enabled },
            set: { onToggleEnabled($0) }
        )
    }

    private var updatedText: String {
        guard let date = subscription.updatedAt else { return "从未更新" }
        return "更新于 " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
