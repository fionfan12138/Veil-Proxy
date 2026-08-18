import Foundation

/// 内核管理：定位内置 mihomo、写配置、启动/停止子进程。
/// 阶段 0.2 用最小配置跑通「启动/停止/健康检查」，完整配置在步骤 1.3 交给 ConfigBuilder。
@MainActor
final class CoreManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var statusMessage = "未启动"

    private var process: Process?
    private var logHandle: FileHandle?

    /// 控制接口端口（AppState 在连接前与 settings 同步，保证 API 客户端与 config.yaml 一致）
    var controllerPort: Int
    /// 共享的 API 客户端实例——不能做成每次访问新建（每秒轮询会不断创建 URLSession，
    /// 会话缓存不清除导致内存持续增长），端口变化时用 syncControllerPort 重建
    private(set) var apiClient: CoreAPIClient

    /// 配置目录：~/Library/Application Support/Veil/config
    private let configDir: URL
    /// 内核输出日志（排查问题用）
    private var logFile: URL { configDir.appendingPathComponent("mihomo.log") }

    /// 内核进程是否真的还活着（isRunning 只表示我们启动过）
    var isProcessAlive: Bool { process?.isRunning ?? false }

    init(controllerPort: Int = 9090) {
        self.controllerPort = controllerPort
        self.apiClient = CoreAPIClient(port: controllerPort)
        self.configDir = Self.defaultConfigDir
    }

    /// 端口变化时同步控制器端口并重建 API 客户端（保持单一共享实例）
    func syncControllerPort(_ port: Int) {
        guard port != controllerPort else { return }
        controllerPort = port
        apiClient = CoreAPIClient(port: port)
    }

    /// 应用支持目录下的 config 目录（取不到时退回当前用户主目录下的相对路径）
    private static var defaultConfigDir: URL {
        let support: URL
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            support = dir
        } else {
            support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return support
            .appendingPathComponent("Veil", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
    }

    /// 启动内核：写配置 → 拉起 mihomo 子进程。config 为空时用最小配置（阶段 0.2 兜底）。
    /// 二进制优先用受管目录里的升级版（内核一键更新后），其次 Bundle 内置版。
    func start(config: String? = nil) async throws {
        stop()
        await killLeftoverMihomo()

        guard let binary = Self.currentBinaryURL() else {
            throw CoreError.binaryNotFound
        }

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // GeoIP 数据库（规则模式 GEOIP,CN,DIRECT 分流依赖）：内置打包，缺失时拷入配置目录。
        // mihomo 找不到库会联网下载，在无法访问 GitHub 的环境里下载会卡死启动、阻塞控制接口
        // （表现为 PATCH /configs 无响应、模式切换失败）。
        let geoipTarget = configDir.appendingPathComponent("geoip.metadb")
        if !FileManager.default.fileExists(atPath: geoipTarget.path),
           let geoipBundle = Bundle.main.url(forResource: "geoip", withExtension: "metadb") {
            try? FileManager.default.copyItem(at: geoipBundle, to: geoipTarget)
        }

        let yaml = config ?? minimalConfig()
        try yaml.write(to: configDir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        // 确保二进制可执行（构建拷贝后保险起见再设一次）
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // 把内核输出写进日志文件，方便排查「启动失败 / 控制接口不通」等问题
        try Data().write(to: logFile)
        let handle = try FileHandle(forWritingTo: logFile)
        logHandle = handle

        let p = Process()
        p.executableURL = binary
        // 关键：把子进程的工作目录设为 config 目录。
        // macOS 图形程序的默认工作目录是根目录 /，若不指定，mihomo 会去 / 找 config.yaml（只读，直接失败）。
        p.currentDirectoryURL = configDir
        p.arguments = ["-d", configDir.path, "-f", "config.yaml"]
        p.standardOutput = handle
        p.standardError = handle
        // 必须挂 terminationHandler：没有它，Process.isRunning 在子进程退出后仍返回 true
        // （Foundation 依赖该回调回收退出状态），速率轮询的「内核死了就停」检查会失效、
        // 持续空打控制器刷 Connection refused。
        // 用 === 校验身份，防止旧进程的退出回调误伤后启动的新进程。
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.isRunning = false
                self.statusMessage = "内核已退出"
            }
        }
        try p.run()

        process = p
        isRunning = true
        statusMessage = "内核已启动"
    }

    /// 停止内核
    func stop() {
        process?.terminate()
        process = nil
        try? logHandle?.close()
        logHandle = nil
        isRunning = false
        statusMessage = "内核已停止"
    }

    /// 杀掉上一次运行遗留的孤儿 mihomo 进程。
    /// 应用被强杀 / Xcode Stop 时，子进程不会随父进程一起退出，会继续占着 7890/9090，
    /// 导致新启动的内核绑定端口失败、而请求实际打到旧进程上。
    private func killLeftoverMihomo() async {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-x", "mihomo"]
            try? p.run()
            p.waitUntilExit()
        }.value
    }

    /// 读取内核日志（可能为空）
    func readLog() -> String {
        guard let data = try? Data(contentsOf: logFile) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 内核版本检查与更新

    /// 受管内核目录（下载升级的内核放这里，不动 App 包，避免签名失效）
    private nonisolated static var supportVeilDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Veil", isDirectory: true)
    }
    nonisolated static var managedBinaryDir: URL { supportVeilDir.appendingPathComponent("core", isDirectory: true) }
    nonisolated static var managedBinaryURL: URL { managedBinaryDir.appendingPathComponent("mihomo") }

    /// 当前生效的内核二进制：受管目录里的升级版优先，其次 Bundle 内置版
    static func currentBinaryURL() -> URL? {
        if FileManager.default.fileExists(atPath: managedBinaryURL.path) {
            return managedBinaryURL
        }
        return Bundle.main.url(forResource: "mihomo", withExtension: nil)
    }

    /// 当前内核版本：运行中走 API；未运行用二进制 `-v` 子进程读取
    func kernelVersion() async -> String? {
        if isProcessAlive, let version = try? await apiClient.kernelVersion(), !version.isEmpty {
            return version
        }
        guard let binary = Self.currentBinaryURL() else { return nil }
        return await Task.detached(priority: .utility) {
            Self.binaryVersion(at: binary)
        }.value
    }

    /// 用 `mihomo -v` 读取二进制版本（如输出 "mihomo version v1.19.29"）
    /// nonisolated：从 Task.detached 后台调用，不占用主线程
    private nonisolated static func binaryVersion(at url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        try? pipe.fileHandleForWriting.close()   // 关父进程写端，读端才能拿到 EOF
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"v[0-9]+\.[0-9]+\.[0-9]+"#) else { return nil }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    /// GitHub 上 MetaCubeX/mihomo 的最新版本号（tag_name；URLSession.shared 走系统代理）
    func latestKernelVersion() async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest") else {
            throw CoreError.updateCheckFailed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CoreError.updateCheckFailed
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let tag = json?["tag_name"] as? String, !tag.isEmpty else {
            throw CoreError.updateCheckFailed
        }
        return tag
    }

    /// 下载并安装新内核到受管目录（下次内核启动时生效；正在运行的内核不受影响）
    func installKernel(version: String) async throws {
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "amd64"
        #else
        throw CoreError.unsupportedArchitecture
        #endif
        guard let assetURL = URL(string:
            "https://github.com/MetaCubeX/mihomo/releases/download/\(version)/mihomo-darwin-\(arch)-\(version).gz"
        ) else { throw CoreError.updateDownloadFailed }

        var request = URLRequest(url: assetURL)
        request.timeoutInterval = 300
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CoreError.updateDownloadFailed
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.managedBinaryDir, withIntermediateDirectories: true)
        let gzURL = Self.managedBinaryDir.appendingPathComponent("mihomo.gz")
        try data.write(to: gzURL, options: .atomic)
        defer { try? fileManager.removeItem(at: gzURL) }

        try await Task.detached(priority: .utility) {
            try Self.gunzip(from: gzURL, to: Self.managedBinaryURL)
        }.value
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.managedBinaryURL.path)
    }

    /// 用系统 gunzip 解压到目标文件（覆盖已有文件安全：运行中的进程持有旧 inode 不受影响）
    /// nonisolated：从 Task.detached 后台调用
    private nonisolated static func gunzip(from input: URL, to output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let outHandle: FileHandle
        do {
            outHandle = try FileHandle(forWritingTo: output)
        } catch {
            throw CoreError.updateInstallFailed
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", input.path]
        process.standardOutput = outHandle
        do {
            try process.run()
        } catch {
            try? outHandle.close()
            throw CoreError.updateInstallFailed
        }
        process.waitUntilExit()
        try? outHandle.close()
        guard process.terminationStatus == 0 else { throw CoreError.updateInstallFailed }
    }

    /// 从指定字节偏移增量读取内核日志，返回 (新增内容, 新偏移)。
    /// 供访问日志解析「using REJECT」等匹配记录（比每次读整个文件高效）。
    func readLogIncrement(from offset: UInt64) -> (text: String, newOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return ("", offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (text, offset + UInt64(data.count))
    }

    /// 阶段 0.2 的最小配置（完整配置在步骤 1.3 由 ConfigBuilder 生成）
    private func minimalConfig() -> String {
        return """
        mixed-port: 7890
        mode: rule
        log-level: info
        external-controller: 127.0.0.1:\(controllerPort)
        """
    }
}

enum CoreError: LocalizedError {
    case binaryNotFound
    case updateCheckFailed
    case updateDownloadFailed
    case updateInstallFailed
    case unsupportedArchitecture

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "找不到内置的 mihomo 内核（应打包在 App 的 Resources 里）"
        case .updateCheckFailed:
            return "检查更新失败（需要能访问 GitHub；连接代理后重试）"
        case .updateDownloadFailed:
            return "内核下载失败"
        case .updateInstallFailed:
            return "内核安装失败"
        case .unsupportedArchitecture:
            return "当前架构暂不支持内核更新"
        }
    }
}
