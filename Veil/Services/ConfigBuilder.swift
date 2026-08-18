import Foundation

/// 由节点 + 设置生成 mihomo 的 config.yaml。
/// 所有节点放进一个 selector 组，末尾 MATCH 规则走该组；mode 直接对应 mihomo mode。
enum ConfigBuilder {

    /// select 组的固定名称（节点选择 / 规则都指向它；AppState 切节点时经 API 引用同一名字）
    static let selectorGroupName = "PROXY"

    static func build(nodes: [ProxyNode], settings: AppSettings) -> String {
        // 把用户选中的节点排到最前：mihomo 的 select 组默认选中第一个，这样「当前节点」才是真正在用的
        let ordered = orderedNodes(nodes, selectedID: settings.selectedNodeID)

        var lines: [String] = []
        lines.append("mixed-port: \(settings.mixedPort)")
        lines.append("mode: \(settings.mode.rawValue)")
        lines.append("log-level: info")
        lines.append("external-controller: 127.0.0.1:\(settings.controllerPort)")
        // 局域网共享（可选用户名密码认证；都填了才启用认证）
        if settings.allowLAN {
            lines.append("allow-lan: true")
            lines.append("bind-address: '*'")
            let user = settings.lanUsername.trimmingCharacters(in: .whitespaces)
            let pass = settings.lanPassword
            if !user.isEmpty, !pass.isEmpty {
                lines.append("authentication:")
                lines.append("  - \(quote("\(user):\(pass)"))")
            }
        }
        // 嗅探器：从 TLS/HTTP 流量提取 SNI/域名。不开的话 QUIC（UDP）等无 CONNECT 头的
        // 流量匹配不到 DOMAIN 类规则，会掉到 MATCH 走代理——表现为「拒了 youtube 但日志仍显示走 PROXY」
        lines.append("sniffer:")
        lines.append("  enable: true")
        lines.append("  sniff:")
        lines.append("    TLS:")
        lines.append("      ports: [443, 8443]")
        lines.append("    HTTP:")
        lines.append("      ports: [80, 8080-8880]")
        lines.append("  parse-pure-ip: true")
        lines.append("")

        if !ordered.isEmpty {
            lines.append("proxies:")
            for node in ordered {
                appendProxy(node, to: &lines)
            }
            lines.append("")
        }

        lines.append("proxy-groups:")
        lines.append("  - name: \(selectorGroupName)")
        lines.append("    type: select")
        lines.append("    proxies:")
        for node in ordered {
            lines.append("      - \(quote(node.name))")
        }
        lines.append("      - DIRECT")
        lines.append("")

        lines.append("rules:")
        // 用户自定义规则优先（步骤 3.5）：按域名/IP 走代理/直连/拒绝，先于默认分流匹配
        for rule in settings.customRules {
            let type: String
            if rule.isIP {
                type = "IP-CIDR"
            } else if rule.isSuffix {
                type = "DOMAIN-SUFFIX"
            } else {
                type = "DOMAIN"
            }
            lines.append("  - \(type),\(rule.domain),\(rule.action.rawValue.uppercased())")
        }
        // 规则模式分流：国内直连、其余走节点（步骤 2.2）
        lines.append("  - GEOIP,CN,DIRECT")
        lines.append("  - MATCH,\(selectorGroupName)")
        return lines.joined(separator: "\n")
    }

    /// 选中的节点排最前，其余保持原顺序
    private static func orderedNodes(_ nodes: [ProxyNode], selectedID: UUID?) -> [ProxyNode] {
        guard let selectedID = selectedID,
              let selected = nodes.first(where: { $0.id == selectedID }) else {
            return nodes
        }
        return [selected] + nodes.filter { $0.id != selectedID }
    }

    // MARK: - 各协议

    private static func appendProxy(_ node: ProxyNode, to lines: inout [String]) {
        switch node.type {
        case .vmess: appendVMess(node, to: &lines)
        case .vless: appendVLESS(node, to: &lines)
        case .trojan: appendTrojan(node, to: &lines)
        case .ss: appendSS(node, to: &lines)
        }
    }

    private static func appendVMess(_ node: ProxyNode, to lines: inout [String]) {
        lines.append("  - name: \(quote(node.name))")
        lines.append("    type: vmess")
        lines.append("    server: \(quote(node.server))")
        lines.append("    port: \(node.port)")
        lines.append("    uuid: \(quote(node.uuid ?? ""))")
        lines.append("    alterId: \(node.alterId)")
        lines.append("    cipher: auto")
        if node.tls {
            lines.append("    tls: true")
            if let sni = node.sni, !sni.isEmpty {
                lines.append("    servername: \(quote(sni))")
            }
        }
        if node.network != "tcp" {
            lines.append("    network: \(node.network)")
        }
        appendTransport(node, to: &lines)
    }

    private static func appendVLESS(_ node: ProxyNode, to lines: inout [String]) {
        lines.append("  - name: \(quote(node.name))")
        lines.append("    type: vless")
        lines.append("    server: \(quote(node.server))")
        lines.append("    port: \(node.port)")
        lines.append("    uuid: \(quote(node.uuid ?? ""))")
        if let flow = node.flow, !flow.isEmpty {
            lines.append("    flow: \(flow)")
        }
        if let fingerprint = node.fingerprint, !fingerprint.isEmpty {
            lines.append("    client-fingerprint: \(fingerprint)")
        }
        if node.tls {
            lines.append("    tls: true")
            if let sni = node.sni, !sni.isEmpty {
                lines.append("    servername: \(quote(sni))")
            }
        }
        if node.network != "tcp" {
            lines.append("    network: \(node.network)")
        }
        appendRealityOpts(node, to: &lines)
        appendTransport(node, to: &lines)
    }

    /// vless reality 的 reality-opts（public-key / short-id）；vision 流需要 udp
    private static func appendRealityOpts(_ node: ProxyNode, to lines: inout [String]) {
        let hasKey = node.publicKey.map { !$0.isEmpty } ?? false
        let hasShortId = node.shortId.map { !$0.isEmpty } ?? false
        guard hasKey || hasShortId else { return }
        lines.append("    udp: true")
        lines.append("    reality-opts:")
        if hasKey {
            lines.append("      public-key: \(quote(node.publicKey ?? ""))")
        }
        if hasShortId {
            lines.append("      short-id: \(quote(node.shortId ?? ""))")
        }
    }

    private static func appendTrojan(_ node: ProxyNode, to lines: inout [String]) {
        lines.append("  - name: \(quote(node.name))")
        lines.append("    type: trojan")
        lines.append("    server: \(quote(node.server))")
        lines.append("    port: \(node.port)")
        lines.append("    password: \(quote(node.password ?? ""))")
        if let sni = node.sni, !sni.isEmpty {
            lines.append("    sni: \(quote(sni))")
        }
        if node.network != "tcp" {
            lines.append("    network: \(node.network)")
        }
        appendTransport(node, to: &lines)
    }

    private static func appendSS(_ node: ProxyNode, to lines: inout [String]) {
        lines.append("  - name: \(quote(node.name))")
        lines.append("    type: ss")
        lines.append("    server: \(quote(node.server))")
        lines.append("    port: \(node.port)")
        lines.append("    cipher: \(node.cipher ?? "aes-128-gcm")")
        lines.append("    password: \(quote(node.password ?? ""))")
    }

    /// ws 传输的 path / Host 头（其它传输方式第一版先不加 opts）
    private static func appendTransport(_ node: ProxyNode, to lines: inout [String]) {
        guard node.network == "ws" else { return }
        let hasPath = node.path.map { !$0.isEmpty } ?? false
        let hasHost = node.host.map { !$0.isEmpty } ?? false
        guard hasPath || hasHost else { return }
        lines.append("    ws-opts:")
        if hasPath {
            lines.append("      path: \(quote(node.path ?? ""))")
        }
        if hasHost {
            lines.append("      headers:")
            lines.append("        Host: \(quote(node.host ?? ""))")
        }
    }

    /// YAML 双引号包裹，转义反斜杠与引号
    private static func quote(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
