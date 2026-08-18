import Foundation
import CFNetwork

/// 一条代理连接（GET /connections 解析结果；isClosed 由 AppState 合并历史时标记，表示已断开）
struct ConnectionInfo: Identifiable, Equatable {
    let id: String
    /// 目标域名（metadata.host；纯 IP 连接可能为空，界面回退显示 destination）
    var host: String
    /// 目标地址（IP:端口）
    var destination: String
    /// 来源地址（IP:端口）
    var source: String
    /// 传输协议（tcp / udp）
    var network: String
    /// 命中的分流规则（如 MATCH / GEOIP,CN,DIRECT）
    var rule: String
    /// 代理链（如 ["DMIT-eb"]；直连为空数组）
    var chains: [String]
    /// 已上传字节（累计）
    var upload: Int64
    /// 已下载字节（累计）
    var download: Int64
    /// 连接建立时间
    var start: Date
    /// 是否已断开（历史条目，界面置灰）
    var isClosed: Bool = false
    /// 被拒绝次数（同一域名短时间内的重复 REJECT 折叠计数，界面显示「已拒绝 ×N」）
    var rejectCount: Int = 1
}

/// mihomo 控制接口客户端。
/// 封装 REST：健康检查（/version）、切节点（PUT /proxies/{group}）。
/// 单节点测速已改为 TCP 直连 ping（见 LatencyProbe），不经内核；切模式（PATCH /configs）留到步骤 2.2。
final class CoreAPIClient {
    private let port: Int
    /// 专用于访问本机控制器的 URLSession：禁用系统代理。
    /// 连接后系统代理指向 127.0.0.1:7890，若控制器请求（127.0.0.1:9090）走代理会被 mihomo 按规则经节点转发，
    /// 永远到不了控制器，导致「连接中切节点」失败。空 connectionProxyDictionary = 直连。
    private let session: URLSession

    init(port: Int = 9090) {
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        // 显式关闭三类代理（HTTP/HTTPS/SOCKS）：控制器请求（127.0.0.1:9090）必须直连。
        // 连接后系统代理指向 127.0.0.1:7890，若此请求走代理会被 mihomo 按规则经节点转发，永远到不了控制器。
        // 空字典在个别 macOS 版本上不会覆盖系统代理，显式 false 最稳。
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
        ]
        self.session = URLSession(configuration: config)
    }

    /// 健康检查：访问 /version，成功返回 true
    func ping() async -> Bool {
        guard let url = url(forPath: "version") else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// 内核版本（GET /version → {"version": "v1.19.29", ...}）
    func kernelVersion() async throws -> String {
        guard let url = url(forPath: "version") else { throw CoreAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CoreAPIError.requestFailed("读取内核版本失败")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["version"] as? String ?? ""
    }

    /// 切换 select 组的选中节点（PUT /proxies/{group}，body {"name": 节点名}）。
    /// 连接中切节点走这里，即时生效，不重启内核。
    func switchProxy(group: String, to proxyName: String) async throws {
        var components = baseComponents()
        components.percentEncodedPath = "/proxies/\(Self.pathComponent(group))"
        guard let url = components.url else { throw CoreAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": proxyName])
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                throw CoreAPIError.requestFailed("切换节点失败（HTTP \(status)）")
            }
        } catch let error as CoreAPIError {
            throw error
        } catch {
            throw CoreAPIError.requestFailed("切换节点失败：\(error.localizedDescription)")
        }
    }

    /// 读回 select 组当前选中项（GET /proxies/{group} → {"now": "节点名", ...}），用于切节点后验证是否真的切过去。
    func currentSelection(group: String) async -> String? {
        var components = baseComponents()
        components.percentEncodedPath = "/proxies/\(Self.pathComponent(group))"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return json?["now"] as? String
        } catch {
            return nil
        }
    }

    /// 断开所有活动连接（DELETE /connections，返回 204）。
    /// 切换节点后调用：已建立的连接不会随 select 组自动迁到新节点，
    /// 不断开的话浏览器 keep-alive 等旧连接继续走旧节点，「切换」看起来不生效。
    func closeAllConnections() async throws {
        var components = baseComponents()
        components.percentEncodedPath = "/connections"
        guard let url = components.url else { throw CoreAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                throw CoreAPIError.requestFailed("断开连接失败（HTTP \(status)）")
            }
        } catch let error as CoreAPIError {
            throw error
        } catch {
            throw CoreAPIError.requestFailed("断开连接失败：\(error.localizedDescription)")
        }
    }

    /// 打开 /traffic 流式连接（GET /traffic → 每秒推一个 JSON 快照、每行一个、永不结束）。
    /// 注意：不能对这个端点用 `data(for:)`（等响应结束会超时抛错）。
    /// 调用方用 `bytes.lines` 逐行读取，用完必须 `bytes.task.cancel()` 主动断开；
    /// 请求走直连 session（已禁用代理）。
    func openTrafficStream() async throws -> URLSession.AsyncBytes {
        guard let url = url(forPath: "traffic") else { throw CoreAPIError.invalidURL }

        var request = URLRequest(url: url)
        // 该超时只约束「收到首个字节」；流本身不结束
        request.timeoutInterval = 5

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CoreAPIError.requestFailed("读取流量失败")
            }
            return bytes
        } catch let error as CoreAPIError {
            throw error
        } catch {
            throw CoreAPIError.requestFailed("读取流量失败：\(error.localizedDescription)")
        }
    }

    /// 切换代理模式（PATCH /configs {"mode": "rule"|"global"|"direct"}，即时生效、不重启内核）
    func setMode(_ mode: ProxyMode) async throws {
        var components = baseComponents()
        components.percentEncodedPath = "/configs"
        guard let url = components.url else { throw CoreAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue])
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                throw CoreAPIError.requestFailed("切换模式失败（HTTP \(status)）")
            }
        } catch let error as CoreAPIError {
            throw error
        } catch {
            throw CoreAPIError.requestFailed("切换模式失败：\(error.localizedDescription)")
        }
    }

    /// 读取当前活动连接列表（GET /connections，普通 JSON 响应，`data(for:)` 可直接用）。
    /// 供访问日志（3.6）每秒轮询；请求走直连 session（已禁用代理）。
    func connections() async throws -> [ConnectionInfo] {
        guard let url = url(forPath: "connections") else { throw CoreAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CoreAPIError.requestFailed("读取连接列表失败")
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let list = json["connections"] as? [[String: Any]] else {
                return []
            }
            return list.compactMap { Self.parseConnection($0) }
        } catch let error as CoreAPIError {
            throw error
        } catch {
            throw CoreAPIError.requestFailed("读取连接列表失败：\(error.localizedDescription)")
        }
    }

    private static func parseConnection(_ item: [String: Any]) -> ConnectionInfo? {
        guard let id = item["id"] as? String else { return nil }
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let destIP = metadata["destinationIP"] as? String ?? ""
        let destPort = metadata["destinationPort"] as? String ?? ""
        let srcIP = metadata["sourceIP"] as? String ?? ""
        let srcPort = metadata["sourcePort"] as? String ?? ""
        return ConnectionInfo(
            id: id,
            host: metadata["host"] as? String ?? "",
            destination: "\(destIP):\(destPort)",
            source: "\(srcIP):\(srcPort)",
            network: metadata["network"] as? String ?? "tcp",
            rule: item["rule"] as? String ?? "",
            chains: item["chains"] as? [String] ?? [],
            upload: (item["upload"] as? NSNumber)?.int64Value ?? 0,
            download: (item["download"] as? NSNumber)?.int64Value ?? 0,
            start: parseDate(item["start"]) ?? Date()
        )
    }

    /// mihomo 的 start 时间戳：2026-08-16T15:55:24.745614000+08:00（含纳秒小数 + 时区）
    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
            ?? ISO8601DateFormatter().date(from: string)
    }

    // MARK: - URL 构造

    private func baseComponents() -> URLComponents {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        return components
    }

    private func url(forPath path: String) -> URL? {
        var components = baseComponents()
        components.path = "/" + path
        return components.url
    }

    /// 把节点名 / 组名编码成安全的路径段（仅保留字母数字与 -._~，其余全部百分号编码）
    private static func pathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum CoreAPIError: LocalizedError {
    case invalidURL
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "控制接口地址无效"
        case .requestFailed(let message):
            return message
        }
    }
}
