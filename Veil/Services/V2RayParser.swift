import Foundation

/// V2Ray 订阅 URI 解析：vmess / vless / trojan / ss → ProxyNode。
/// 第一版覆盖四种协议常见写法；reality、ss 插件、grpc 细节等特殊字段后续再补。
enum V2RayParser {

    /// 解析单条 URI，失败返回 nil（跳过该行，不中断整批）。
    static func parse(_ raw: String) -> ProxyNode? {
        let uri = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else { return nil }

        var node: ProxyNode?
        if uri.hasPrefix("vmess://") {
            node = parseVMess(String(uri.dropFirst("vmess://".count)))
        } else if uri.hasPrefix("vless://") {
            node = parseVLESS(String(uri.dropFirst("vless://".count)))
        } else if uri.hasPrefix("trojan://") {
            node = parseTrojan(String(uri.dropFirst("trojan://".count)))
        } else if uri.hasPrefix("ss://") {
            node = parseSS(String(uri.dropFirst("ss://".count)))
        } else {
            return nil
        }
        guard var parsed = node else { return nil }
        // 过滤机场拼在节点名里的流量后缀（如「DMIT-eb|📊817.45GB」→「DMIT-eb」）
        parsed.name = sanitizedName(parsed.name)
        return parsed
    }

    // MARK: - vmess（base64 编码的 JSON）

    private static func parseVMess(_ body: String) -> ProxyNode? {
        guard let json = decodeBase64(body),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = obj["add"] as? String, !server.isEmpty else {
            return nil
        }

        let name = (obj["ps"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? server
        let port = intValue(obj["port"])
        let uuid = obj["id"] as? String ?? ""
        let alterId = intValue(obj["aid"])
        let network = obj["net"] as? String ?? "tcp"
        let tls = (obj["tls"] as? String) == "tls"
        let sni = (obj["sni"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let host = (obj["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let path = (obj["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return ProxyNode(
            name: name, type: .vmess, server: server, port: port,
            uuid: uuid, alterId: alterId, tls: tls, sni: sni, host: host, path: path, network: network
        )
    }

    // MARK: - vless / trojan（URI 查询参数）

    private static func parseVLESS(_ body: String) -> ProxyNode? {
        guard let url = URLComponents(string: "vless://" + body),
              let uuid = url.user, !uuid.isEmpty,
              let server = url.host, !server.isEmpty,
              let port = url.port else { return nil }

        let query = url.queryItems ?? []
        let security = value("security", in: query) ?? "none"

        let name = url.fragment?.removingPercentEncoding ?? server
        // tls 或 reality 都视为开启 TLS
        let tls = security == "tls" || security == "reality"
        let sni = value("sni", in: query) ?? value("servername", in: query)
        let host = value("host", in: query)
        let path = value("path", in: query)
        let network = value("type", in: query) ?? "tcp"
        let flow = value("flow", in: query)

        // reality 字段：pbk（公钥）、sid（short-id）、fp（指纹）。
        // 部分机场用 spiderX（spx）替代标准 reality 的 pbk；没有 pbk 时回退到 spx，
        // 避免漏掉公钥导致 reality-opts 为空、mihomo 握手失败（表现为「连接后上不了网」）。
        let publicKey = value("pbk", in: query) ?? value("spx", in: query)
        let shortId = value("sid", in: query)
        let fingerprint = value("fp", in: query)

        return ProxyNode(
            name: name, type: .vless, server: server, port: port,
            uuid: uuid, tls: tls, sni: sni, host: host, path: path, network: network, flow: flow,
            publicKey: publicKey, shortId: shortId, fingerprint: fingerprint
        )
    }

    private static func parseTrojan(_ body: String) -> ProxyNode? {
        guard let url = URLComponents(string: "trojan://" + body),
              let password = url.user?.removingPercentEncoding, !password.isEmpty,
              let server = url.host, !server.isEmpty,
              let port = url.port else { return nil }

        let query = url.queryItems ?? []
        let security = value("security", in: query) ?? "tls"
        let name = url.fragment?.removingPercentEncoding ?? server
        let tls = security == "tls"
        let sni = value("sni", in: query) ?? value("servername", in: query)
        let host = value("host", in: query)
        let path = value("path", in: query)
        let network = value("type", in: query) ?? "tcp"

        return ProxyNode(
            name: name, type: .trojan, server: server, port: port,
            password: password, tls: tls, sni: sni, host: host, path: path, network: network
        )
    }

    // MARK: - ss（SIP002 / 旧式 base64）

    private static func parseSS(_ body: String) -> ProxyNode? {
        let parts = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(parts[0])
        let name = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""

        if core.contains("@") {
            // SIP002：ss://base64(method:password)@server:port#name
            guard let at = core.firstIndex(of: "@") else { return nil }
            let userInfoB64 = String(core[..<at])
            let addr = String(core[core.index(after: at)...])
            guard let userInfo = decodeBase64(userInfoB64) else { return nil }
            let methodPassword = userInfo.split(separator: ":", maxSplits: 1)
            guard methodPassword.count == 2 else { return nil }
            guard let (server, port) = parseHostPort(addr) else { return nil }
            return ProxyNode(
                name: name.isEmpty ? server : name, type: .ss, server: server, port: port,
                password: String(methodPassword[1]), cipher: String(methodPassword[0])
            )
        } else {
            // 旧式：整个 core 是 base64(method:password@server:port)
            guard let decoded = decodeBase64(core),
                  let at = decoded.firstIndex(of: "@") else { return nil }
            let methodPassword = decoded[..<at].split(separator: ":", maxSplits: 1)
            guard methodPassword.count == 2 else { return nil }
            let addr = String(decoded[decoded.index(after: at)...])
            guard let (server, port) = parseHostPort(addr) else { return nil }
            return ProxyNode(
                name: name.isEmpty ? server : name, type: .ss, server: server, port: port,
                password: String(methodPassword[1]), cipher: String(methodPassword[0])
            )
        }
    }

    // MARK: - 辅助

    /// 过滤机场拼在节点名里的流量后缀（如「DMIT-eb|📊817.45GB」→「DMIT-eb」）。
    /// 只截「📊」所在的最后一段：📊 往前最近的 | 连同其后内容一并截掉；
    /// 不含 📊 的名字原样返回，不影响「HK|IEPL|01」这类用 | 分组的正常名字。
    private static func sanitizedName(_ name: String) -> String {
        guard let marker = name.range(of: "📊") else { return name }
        let prefix = name[..<marker.lowerBound]
        let cutIndex = prefix.lastIndex(of: "|") ?? prefix.endIndex
        return String(name[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }

    private static func intValue(_ any: Any?) -> Int {
        if let number = any as? NSNumber { return number.intValue }
        if let string = any as? String { return Int(string) ?? 0 }
        return 0
    }

    /// 解析 host:port，兼容 [ipv6]:port
    private static func parseHostPort(_ string: String) -> (String, Int)? {
        if string.hasPrefix("[") {
            guard let close = string.firstIndex(of: "]") else { return nil }
            let host = String(string[string.index(after: string.startIndex)..<close])
            let rest = string[string.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            guard let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = string.lastIndex(of: ":") else { return nil }
        let host = String(string[..<colon])
        guard let port = Int(string[string.index(after: colon)...]) else { return nil }
        return (host, port)
    }

    /// 通用 base64 解码：自动补齐填充，兼容 URL-safe 字符（订阅内容与 ss 用户信息共用）
    static func decodeBase64(_ string: String) -> String? {
        let cleaned = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded: String
        let remainder = cleaned.count % 4
        padded = remainder == 0 ? cleaned : cleaned + String(repeating: "=", count: 4 - remainder)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
