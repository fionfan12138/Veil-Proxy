import Foundation

/// 订阅响应头 Subscription-Userinfo 解析出的流量配额（单位：字节）。
struct SubscriptionUserInfo {
    let totalBytes: Int64
    let usedBytes: Int64

    /// 解析形如 "upload=1; download=2; total=3; expire=4" 的头；无 total（或 ≤0）返回 nil。
    static func parse(_ header: String) -> SubscriptionUserInfo? {
        var upload: Int64 = 0
        var download: Int64 = 0
        var total: Int64?
        for part in header.components(separatedBy: ";") {
            let kv = part.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            guard let num = Int64(value) else { continue }
            switch key {
            case "upload": upload = num
            case "download": download = num
            case "total": total = num
            default: break
            }
        }
        guard let total = total, total > 0 else { return nil }
        // 诊断：打印原始字节值，便于核对配额换算（total/upload/download 均为字节）
        print("[SubscriptionUserInfo] raw bytes → total=\(total), upload=\(upload), download=\(download)")
        return SubscriptionUserInfo(totalBytes: total, usedBytes: upload + download)
    }
}

/// 一次订阅拉取的结果：节点列表 + 可选的流量配额信息。
struct SubscriptionFetchResult {
    let nodes: [ProxyNode]
    let userInfo: SubscriptionUserInfo?
}

/// 订阅拉取 + base64 解码 + 解析成节点列表。
final class SubscriptionService {

    /// 拉取并解析一个订阅，返回去重后的节点列表 + 流量配额信息（如有）。
    func fetch(from urlString: String) async throws -> SubscriptionFetchResult {
        guard let url = URL(string: urlString) else {
            throw SubscriptionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // 部分订阅服务会拦截非浏览器 User-Agent，用浏览器 UA 兜底
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        var userInfo: SubscriptionUserInfo?
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw SubscriptionError.httpStatus(http.statusCode)
            }
            // 机场通常在响应头带流量配额；`value(forHTTPHeaderField:)` 大小写不敏感
            if let header = http.value(forHTTPHeaderField: "Subscription-Userinfo") {
                userInfo = SubscriptionUserInfo.parse(header)
            }
        }

        guard let content = decodeContent(data) else {
            if looksLikeClashYAML(data) {
                throw SubscriptionError.unsupportedFormat
            }
            throw SubscriptionError.decodeFailed
        }
        return SubscriptionFetchResult(nodes: parseContent(content), userInfo: userInfo)
    }

    /// 订阅内容可能是明文 URI 列表，也可能是 base64 编码的文本。
    private func decodeContent(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://") { return trimmed }

        // 尝试 base64 解码（最多几层）
        var candidate = trimmed
        for _ in 0..<3 {
            guard let decoded = V2RayParser.decodeBase64(candidate) else { return nil }
            if decoded.contains("://") { return decoded }
            candidate = decoded
        }
        return nil
    }

    /// 判断是否 Clash 订阅（YAML，含 proxies: / proxy-groups: 段落）
    private func looksLikeClashYAML(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [trimmed]
        if let decoded = V2RayParser.decodeBase64(trimmed) {
            candidates.append(decoded)
        }
        return candidates.contains { $0.contains("proxies:") || $0.contains("proxy-groups:") }
    }

    /// 逐行解析，按 server:port 去重，跳过无法解析的行。
    private func parseContent(_ content: String) -> [ProxyNode] {
        var nodes: [ProxyNode] = []
        var seen = Set<String>()
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("vmess://")
                || trimmed.hasPrefix("vless://")
                || trimmed.hasPrefix("trojan://")
                || trimmed.hasPrefix("ss://") else { continue }
            guard let node = V2RayParser.parse(trimmed) else { continue }
            let key = "\(node.server):\(node.port)"
            if seen.insert(key).inserted {
                nodes.append(node)
            }
        }
        return nodes
    }
}

enum SubscriptionError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case decodeFailed
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "订阅链接无效"
        case .httpStatus(let code): return "订阅请求失败（HTTP \(code)）"
        case .decodeFailed: return "订阅内容解析失败"
        case .unsupportedFormat: return "暂不支持该订阅格式（当前只支持 vmess/vless/trojan/ss 链接列表，Clash YAML 订阅后续支持）"
        }
    }
}
