import Foundation

/// 代理订阅（一个订阅链接对应一批节点）
struct Subscription: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// 订阅名称（用户自定义显示名）
    var name: String
    /// 订阅链接（V2Ray base64 或机场链接）
    var url: String
    /// 是否启用（参与节点合并）
    var enabled: Bool
    /// 上次成功更新时间
    var updatedAt: Date?
    /// 流量配额总量（字节，从订阅响应头 Subscription-Userinfo 解析）；nil = 机场未提供
    var totalBytes: Int64?
    /// 已用流量（字节，上传 + 下载）；nil = 机场未提供
    var usedBytes: Int64?
    /// 标签颜色（#RRGGBB）；nil = 默认蓝（accent）
    var colorHex: String?

    init(
        name: String,
        url: String,
        enabled: Bool = true,
        updatedAt: Date? = nil,
        totalBytes: Int64? = nil,
        usedBytes: Int64? = nil,
        colorHex: String? = nil
    ) {
        self.name = name
        self.url = url
        self.enabled = enabled
        self.updatedAt = updatedAt
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, enabled, updatedAt, totalBytes, usedBytes, colorHex
    }

    /// 兼容旧数据：colorHex 为后加字段，缺失按 nil（默认蓝）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        usedBytes = try container.decodeIfPresent(Int64.self, forKey: .usedBytes)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
    }

    /// 剩余流量（字节）；total/used 任一缺失返回 nil
    var remainingBytes: Int64? {
        guard let total = totalBytes, let used = usedBytes else { return nil }
        return max(0, total - used)
    }

    /// 剩余流量占比（0~1），供进度条使用；total/used 任一缺失返回 nil
    var remainingFraction: Double? {
        guard let total = totalBytes, total > 0, let remaining = remainingBytes else { return nil }
        return min(1, max(0, Double(remaining) / Double(total)))
    }
}
