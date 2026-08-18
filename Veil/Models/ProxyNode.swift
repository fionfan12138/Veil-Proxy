import Foundation

/// 节点协议类型（对应 V2Ray 的四种常见协议）
enum ProxyType: String, Codable, CaseIterable {
    case vmess
    case vless
    case trojan
    case ss

    /// 协议徽标显示名
    var displayName: String {
        switch self {
        case .vmess: return "VMess"
        case .vless: return "VLESS"
        case .trojan: return "Trojan"
        case .ss: return "SS"
        }
    }
}

/// 单个代理节点。
/// 用「平铺 + 可选字段」容纳四种协议的不同参数，未用到的字段为 nil。
struct ProxyNode: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    /// 节点名称（列表里显示）
    var name: String
    /// 协议类型
    var type: ProxyType
    /// 服务器地址
    var server: String
    /// 端口
    var port: Int

    // —— 各协议用到的字段 ——
    /// vmess / vless 的用户 ID（UUID）
    var uuid: String?
    /// ss / trojan 的密码
    var password: String?
    /// ss 加密方式（如 aes-128-gcm）
    var cipher: String?
    /// vmess 的 alterId
    var alterId: Int
    /// 是否开启 TLS（vmess / vless / trojan）
    var tls: Bool
    /// TLS 服务器名（sni）
    var sni: String?
    /// 伪装域名 / ws host
    var host: String?
    /// ws 路径
    var path: String?
    /// 传输方式：tcp / ws / grpc
    var network: String
    /// vless 的 flow（如 xtls-rprx-vision）
    var flow: String?
    /// vless reality 公钥（pbk）
    var publicKey: String?
    /// vless reality short-id（sid）
    var shortId: String?
    /// 客户端指纹（fp，如 chrome；reality / utls 用）
    var fingerprint: String?
    /// 所属订阅 ID（用于按订阅分组展示流量）；手动/老数据节点为 nil
    var subscriptionID: UUID?

    init(
        name: String,
        type: ProxyType,
        server: String,
        port: Int,
        uuid: String? = nil,
        password: String? = nil,
        cipher: String? = nil,
        alterId: Int = 0,
        tls: Bool = false,
        sni: String? = nil,
        host: String? = nil,
        path: String? = nil,
        network: String = "tcp",
        flow: String? = nil,
        publicKey: String? = nil,
        shortId: String? = nil,
        fingerprint: String? = nil,
        subscriptionID: UUID? = nil
    ) {
        self.name = name
        self.type = type
        self.server = server
        self.port = port
        self.uuid = uuid
        self.password = password
        self.cipher = cipher
        self.alterId = alterId
        self.tls = tls
        self.sni = sni
        self.host = host
        self.path = path
        self.network = network
        self.flow = flow
        self.publicKey = publicKey
        self.shortId = shortId
        self.fingerprint = fingerprint
        self.subscriptionID = subscriptionID
    }
}
