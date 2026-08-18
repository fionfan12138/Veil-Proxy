import Foundation

/// 代理模式（对应 mihomo 的 mode: rule / global / direct）
enum ProxyMode: String, Codable, CaseIterable {
    case rule
    case global
    case direct

    /// 界面上显示的中文名
    var displayName: String {
        switch self {
        case .rule: return "规则"
        case .global: return "全局"
        case .direct: return "直连"
        }
    }
}

/// 界面外观（设置页「外观」选项）
enum AppAppearance: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 用户自定义分流规则（步骤 3.5）：按域名指定走代理 / 直连 / 拒绝连接
struct CustomRule: Codable, Hashable, Identifiable {
    enum Action: String, Codable, CaseIterable {
        case proxy
        case direct
        case reject

        var displayName: String {
            switch self {
            case .proxy: return "走代理"
            case .direct: return "直连"
            case .reject: return "拒绝"
            }
        }
    }

    var id: UUID = UUID()
    /// 匹配目标：域名（如 youtube.com）或 IP 地址（isIP = true 时）
    var domain: String
    /// true = 匹配该域名及其所有子域名（DOMAIN-SUFFIX）；false = 仅精确匹配（DOMAIN）
    var isSuffix: Bool
    var action: Action
    /// true = 按 IP 匹配（IP-CIDR 规则；访问日志一键添加纯 IP 连接时使用）
    var isIP: Bool = false

    init(id: UUID = UUID(), domain: String, isSuffix: Bool, action: Action, isIP: Bool = false) {
        self.id = id
        self.domain = domain
        self.isSuffix = isSuffix
        self.action = action
        self.isIP = isIP
    }

    private enum CodingKeys: String, CodingKey {
        case id, domain, isSuffix, action, isIP
    }

    /// 兼容旧数据：isIP 为后加字段，缺失按 false 处理（否则老规则解码失败被整体丢弃）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        domain = try container.decode(String.self, forKey: .domain)
        isSuffix = try container.decodeIfPresent(Bool.self, forKey: .isSuffix) ?? true
        action = try container.decode(Action.self, forKey: .action)
        isIP = try container.decodeIfPresent(Bool.self, forKey: .isIP) ?? false
    }
}

/// 应用设置（存 UserDefaults）
struct AppSettings: Codable {
    /// 系统代理端口默认值（mihomo mixed-port）
    static let defaultMixedPort = 7890
    /// 控制接口端口默认值
    static let defaultControllerPort = 9090

    /// 系统代理端口（mihomo mixed-port）
    var mixedPort: Int
    /// 内核控制接口端口
    var controllerPort: Int
    /// 当前代理模式
    var mode: ProxyMode
    /// 上次选择的节点 ID
    var selectedNodeID: UUID?
    /// 自定义分流规则（按域名）
    var customRules: [CustomRule]
    /// 是否开启订阅自动更新（定时刷新全部订阅的流量配额/节点）
    var autoRefreshSubscriptions: Bool
    /// 自动更新间隔（小时）
    var autoRefreshIntervalHours: Int
    /// 界面外观（跟随系统 / 浅色 / 深色）
    var appearance: AppAppearance
    /// 是否开启实时速率（首页曲线；关闭即停止 /traffic 轮询）
    var enableSpeedChart: Bool
    /// 是否开启访问日志（关闭即停止 /connections 轮询）
    var enableConnectionLogs: Bool
    /// 是否开机自启（SMAppService 登录项）
    var autoLaunchAtLogin: Bool
    /// 是否允许局域网共享（其它设备经本机代理上网）
    var allowLAN: Bool
    /// 局域网代理认证用户名（可选；空 = 无认证）
    var lanUsername: String
    /// 局域网代理认证密码（可选）
    var lanPassword: String

    init(
        mixedPort: Int = AppSettings.defaultMixedPort,
        controllerPort: Int = AppSettings.defaultControllerPort,
        mode: ProxyMode = .rule,
        selectedNodeID: UUID? = nil,
        customRules: [CustomRule] = [],
        autoRefreshSubscriptions: Bool = false,
        autoRefreshIntervalHours: Int = 6,
        appearance: AppAppearance = .system,
        enableSpeedChart: Bool = true,
        enableConnectionLogs: Bool = true,
        autoLaunchAtLogin: Bool = false,
        allowLAN: Bool = false,
        lanUsername: String = "",
        lanPassword: String = ""
    ) {
        self.mixedPort = mixedPort
        self.controllerPort = controllerPort
        self.mode = mode
        self.selectedNodeID = selectedNodeID
        self.customRules = customRules
        self.autoRefreshSubscriptions = autoRefreshSubscriptions
        self.autoRefreshIntervalHours = autoRefreshIntervalHours
        self.appearance = appearance
        self.enableSpeedChart = enableSpeedChart
        self.enableConnectionLogs = enableConnectionLogs
        self.autoLaunchAtLogin = autoLaunchAtLogin
        self.allowLAN = allowLAN
        self.lanUsername = lanUsername
        self.lanPassword = lanPassword
    }

    private enum CodingKeys: String, CodingKey {
        case mixedPort, controllerPort, mode, selectedNodeID, customRules
        case autoRefreshSubscriptions, autoRefreshIntervalHours, appearance
        case enableSpeedChart, enableConnectionLogs, autoLaunchAtLogin
        case allowLAN, lanUsername, lanPassword
    }

    /// 兼容旧数据：后加字段缺失时按默认值处理（否则老设置解码失败被整体丢弃）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? AppSettings.defaultMixedPort
        controllerPort = try container.decodeIfPresent(Int.self, forKey: .controllerPort) ?? AppSettings.defaultControllerPort
        mode = try container.decodeIfPresent(ProxyMode.self, forKey: .mode) ?? .rule
        selectedNodeID = try container.decodeIfPresent(UUID.self, forKey: .selectedNodeID)
        customRules = try container.decodeIfPresent([CustomRule].self, forKey: .customRules) ?? []
        autoRefreshSubscriptions = try container.decodeIfPresent(Bool.self, forKey: .autoRefreshSubscriptions) ?? false
        autoRefreshIntervalHours = try container.decodeIfPresent(Int.self, forKey: .autoRefreshIntervalHours) ?? 6
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        enableSpeedChart = try container.decodeIfPresent(Bool.self, forKey: .enableSpeedChart) ?? true
        enableConnectionLogs = try container.decodeIfPresent(Bool.self, forKey: .enableConnectionLogs) ?? true
        autoLaunchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .autoLaunchAtLogin) ?? false
        allowLAN = try container.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        lanUsername = try container.decodeIfPresent(String.self, forKey: .lanUsername) ?? ""
        lanPassword = try container.decodeIfPresent(String.self, forKey: .lanPassword) ?? ""
    }
}
