import SwiftUI

/// Veil 品牌「V」字标记；同时用作连接状态视觉（激活=强调色，未激活=次要灰）。
struct BrandMark: View {
    var size: CGFloat
    var isActive: Bool

    private var lineWidth: CGFloat { max(2.0, size * 0.10) }

    var body: some View {
        VShape()
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .foregroundColor(isActive ? .accentColor : Color.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 向下的「V」字形路径（归一化到所在 rect，由 frame 控制实际大小）
private struct VShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
