import Foundation

/// 本地持久化：设置存 UserDefaults，订阅/节点存 JSON 文件。
/// 数据目录：~/Library/Application Support/Veil/data/
final class Persistence {
    static let shared = Persistence()

    private static let settingsKey = "com.veil.appSettings"

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// 数据目录（订阅/节点 JSON 所在处）
    private let dataDirectory: URL

    private init() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        self.encoder = e

        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d

        self.dataDirectory = Self.defaultDataDirectory
    }

    // MARK: - 路径

    private static var defaultDataDirectory: URL {
        let support: URL
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            support = dir
        } else {
            support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return support
            .appendingPathComponent("Veil", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
    }

    // MARK: - 订阅

    func loadSubscriptions() -> [Subscription] {
        return load([Subscription].self, from: "subscriptions.json") ?? []
    }

    func saveSubscriptions(_ subscriptions: [Subscription]) throws {
        try save(subscriptions, to: "subscriptions.json")
    }

    // MARK: - 节点

    func loadNodes() -> [ProxyNode] {
        return load([ProxyNode].self, from: "nodes.json") ?? []
    }

    func saveNodes(_ nodes: [ProxyNode]) throws {
        try save(nodes, to: "nodes.json")
    }

    // MARK: - 设置（UserDefaults）

    func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        let data = try encoder.encode(settings)
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    // MARK: - 底层读写

    private func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        let url = dataDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to fileName: String) throws {
        try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        let url = dataDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
    }
}
