import Foundation
import SystemConfiguration

/// 系统代理管理：通过 networksetup 设置 / 清除 HTTP、HTTPS、SOCKS 系统代理。
///
/// - 写入路径（enable/disable）为 async，用 readabilityHandler + terminationHandler
///   事件驱动地执行进程，完全不阻塞任何线程（包括主线程）。
/// - 检测路径（pointsToProxy）直接读取 SystemConfiguration 当前有效配置，不启动子进程。
/// - 退出路径（disableSync）为同步，仅供 applicationWillTerminate 在退出前阻塞式还原代理。
/// - stdout/stderr 各用一根独立 Pipe、由 readabilityHandler 增量读取，天然避免 pipe buffer 填满死锁。
final class SystemProxyManager {
    static let shared = SystemProxyManager()
    private init() {}

    private let networksetup = "/usr/sbin/networksetup"
    private let proxyHost = "127.0.0.1"
    private let sudoPath = "/usr/bin/sudo"
    /// 免密 sudo（sudoers NOPASSWD 规则）是否可用；nil=未知，缓存探针结果避免每次连接都探
    private var sudoAvailable: Bool?

    enum ProxyError: LocalizedError {
        case noActiveServices
        case commandFailed(String)
        case invalidUsername

        var errorDescription: String? {
            switch self {
            case .noActiveServices:
                return "未找到活动的网络服务"
            case .commandFailed(let message):
                return message
            case .invalidUsername:
                return "当前用户名含特殊字符，无法写入免密规则"
            }
        }
    }

    // MARK: - 异步 API（交互路径）

    /// 设置系统代理（HTTP / HTTPS / SOCKS 均指向 127.0.0.1:port，并开启状态）
    func enable(port: Int) async throws {
        let services = try await activeNetworkServices()

        // 优先走免密 sudo（首次会弹一次授权装 sudoers 规则）；失败回退到逐次弹框的 osascript 提权
        if await ensurePasswordlessSudo(attemptInstall: true) {
            do {
                for args in enableArguments(services: services, port: port) {
                    try await runSudo(args)
                }
                return
            } catch {
                sudoAvailable = false   // 竞态兜底：规则装好又被删
            }
        }
        try await runPrivileged(joinedCommand(enableArguments(services: services, port: port)))
    }

    /// 清除系统代理（关闭三项代理状态，恢复直连）。尽力而为，失败不抛出。
    func disable() async {
        guard let services = try? await activeNetworkServices() else { return }
        let batches = disableArguments(services: services)
        guard !batches.isEmpty else { return }

        // 断开不主动弹框安装；sudo 可用则静默还原，否则回退 osascript 提权
        if await ensurePasswordlessSudo(attemptInstall: false) {
            do {
                for args in batches {
                    try await runSudo(args)
                }
                return
            } catch {
                sudoAvailable = false   // 竞态兜底：规则装好又被删
            }
        }
        try? await runPrivileged(joinedCommand(batches))
    }

    /// 当前有效 HTTP / HTTPS / SOCKS 是否都已开启并指向本应用端口。
    /// SCDynamicStoreCopyProxies 读取的是系统当前实际采用的代理配置，适合识别其它代理软件的接管。
    func pointsToProxy(port: Int) -> Bool {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }

        func matches(enableKey: CFString, hostKey: CFString, portKey: CFString) -> Bool {
            let enabled = (proxies[enableKey as String] as? NSNumber)?.boolValue == true
            let host = proxies[hostKey as String] as? String
            let configuredPort = (proxies[portKey as String] as? NSNumber)?.intValue
            return enabled && host == proxyHost && configuredPort == port
        }

        return matches(
            enableKey: kSCPropNetProxiesHTTPEnable,
            hostKey: kSCPropNetProxiesHTTPProxy,
            portKey: kSCPropNetProxiesHTTPPort
        ) && matches(
            enableKey: kSCPropNetProxiesHTTPSEnable,
            hostKey: kSCPropNetProxiesHTTPSProxy,
            portKey: kSCPropNetProxiesHTTPSPort
        ) && matches(
            enableKey: kSCPropNetProxiesSOCKSEnable,
            hostKey: kSCPropNetProxiesSOCKSProxy,
            portKey: kSCPropNetProxiesSOCKSPort
        )
    }

    // MARK: - 同步 API（仅退出路径，会阻塞当前线程）

    /// 同步清除系统代理。仅供应用退出前调用，确保退出时一定还原。
    func disableSync() {
        guard let listResult = try? Self.runProcessSync(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "\(networksetup) -listallnetworkservices"]
        ) else { return }
        let services = parseServices(listResult.output)
        let batches = disableArguments(services: services)
        guard !batches.isEmpty else { return }

        // 退出路径优先静默还原（免密 sudo）；不可用则回退 osascript 同步提权
        if sudoNetworksetupSync(batches) { return }
        let script = "do shell script \"\(shellEscape(joinedCommand(batches)))\" with administrator privileges"
        _ = try? Self.runProcessSync(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script])
    }

    // MARK: - 异步底层命令

    private func activeNetworkServices() async throws -> [String] {
        guard let output = await run("\(networksetup) -listallnetworkservices") else {
            throw ProxyError.noActiveServices
        }
        let services = parseServices(output)
        guard !services.isEmpty else { throw ProxyError.noActiveServices }
        return services
    }

    /// 普通命令（读取用，无需管理员）
    private func run(_ command: String) async -> String? {
        guard let result = try? await Self.runProcess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", command]
        ) else { return nil }
        return result.output
    }

    /// 提权命令：经 osascript `do shell script ... with administrator privileges` 执行。
    /// 超时放宽到 120s：管理员授权框需要等用户输入密码，不能用默认 15s 看门狗。
    private func runPrivileged(_ command: String) async throws {
        let script = "do shell script \"\(shellEscape(command))\" with administrator privileges"
        let result = try await Self.runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            timeout: 120
        )
        guard result.status == 0 else {
            throw ProxyError.commandFailed(result.output.isEmpty ? "提权命令执行失败" : result.output)
        }
    }

    // MARK: - sudoers 免密（NOPASSWD networksetup）

    /// 当前登录用户名（短账号名，如 yifan）；sudoers 规则需要
    private func currentUsername() -> String { NSUserName() }

    /// 用户名只允许字母数字与 ._-，避免特殊字符写坏 sudoers 或注入
    private func isValidUsername(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// 要写入 sudoers 的规则内容
    private func sudoersRule() -> String {
        "\(currentUsername()) ALL = (ALL) NOPASSWD: \(networksetup)"
    }

    /// 一次性提权安装 sudoers 规则（弹一次系统授权框）。
    /// 用带点临时名 + visudo 校验 + 原子 mv，避免写坏 sudoers 导致 sudo 全局失效。
    private func installSudoersRule() async throws {
        let user = currentUsername()
        guard isValidUsername(user) else { throw ProxyError.invalidUsername }
        let rule = sudoersRule()
        // 规则仅含安全字符，用 echo 单引号包裹，避开跨层反斜杠转义
        let installCmd = "umask 077 && echo '\(rule)' > /etc/sudoers.d/veil.tmp"
            + " && /bin/chmod 0440 /etc/sudoers.d/veil.tmp"
            + " && /usr/sbin/visudo -cf /etc/sudoers.d/veil.tmp"
            + " && /bin/mv /etc/sudoers.d/veil.tmp /etc/sudoers.d/veil"
        try await runPrivileged(installCmd)
    }

    /// 探针：判断免密 sudo 是否已生效（用真实 networksetup 规则，退出码 0 表示可用）
    private func probeSudoPasswordless() async -> Bool {
        guard let result = try? await Self.runProcess(
            executable: URL(fileURLWithPath: sudoPath),
            arguments: ["-n", networksetup, "-version"]
        ) else { return false }
        return result.status == 0
    }

    /// 确保免密 sudo 可用：命中缓存直接返回；否则探针 →（可选）安装 → 再探
    private func ensurePasswordlessSudo(attemptInstall: Bool) async -> Bool {
        if sudoAvailable == true { return true }
        if await probeSudoPasswordless() { sudoAvailable = true; return true }
        if attemptInstall {
            if (try? await installSudoersRule()) != nil, await probeSudoPasswordless() {
                sudoAvailable = true
                return true
            }
        }
        sudoAvailable = false
        return false
    }

    /// 免密执行 networksetup（sudo -n）。
    /// 关键：必须直传 networksetup 本体——sudoers 规则只匹配它；经 /bin/bash -c 包装后
    /// sudo 匹配到的命令是 bash，NOPASSWD 规则不生效、会要求密码（表现为每次都弹授权框）。
    private func runSudo(_ arguments: [String]) async throws {
        let result = try await Self.runProcess(
            executable: URL(fileURLWithPath: sudoPath),
            arguments: ["-n", networksetup] + arguments
        )
        guard result.status == 0 else {
            throw ProxyError.commandFailed(result.output.isEmpty ? "免密执行失败" : result.output)
        }
    }

    /// 同步版免密执行（仅退出路径 disableSync 用）；任一命令失败返回 false
    private func sudoNetworksetupSync(_ batches: [[String]]) -> Bool {
        for args in batches {
            guard let result = try? Self.runProcessSync(
                executable: URL(fileURLWithPath: sudoPath),
                arguments: ["-n", networksetup] + args
            ), result.status == 0 else { return false }
        }
        return true
    }

    // MARK: - 命令构造

    /// 开代理的 networksetup 参数批（免密路径逐条执行；osascript 回退路径合并成一条链）
    private func enableArguments(services: [String], port: Int) -> [[String]] {
        let portString = String(port)
        return services.flatMap { service in
            [
                ["-setwebproxy", service, proxyHost, portString],
                ["-setsecurewebproxy", service, proxyHost, portString],
                ["-setsocksfirewallproxy", service, proxyHost, portString],
                ["-setwebproxystate", service, "on"],
                ["-setsecurewebproxystate", service, "on"],
                ["-setsocksfirewallproxystate", service, "on"],
            ]
        }
    }

    /// 关代理的 networksetup 参数批
    private func disableArguments(services: [String]) -> [[String]] {
        services.flatMap { service in
            [
                ["-setwebproxystate", service, "off"],
                ["-setsecurewebproxystate", service, "off"],
                ["-setsocksfirewallproxystate", service, "off"],
            ]
        }
    }

    /// 把参数批合并成一条 && 命令链（osascript 回退路径：一次提权全部执行）
    private func joinedCommand(_ batches: [[String]]) -> String {
        batches.map { args in
            ([networksetup] + args.map { shellQuote($0) }).joined(separator: " ")
        }.joined(separator: " && ")
    }

    // MARK: - 进程执行（静态，不依赖实例状态）

    /// 异步执行进程：readabilityHandler 增量读 stdout/stderr + terminationHandler 汇总，
    /// 事件驱动，全程不阻塞任何线程。
    /// 极端情况下管道 EOF 可能迟迟不来（如子进程把管道写端留给孙进程），
    /// 三个收尾条件凑不齐 → continuation 泄漏、调用方永久挂起；
    /// 因此加看门狗：timeout 后强杀进程并强制收尾，保证 continuation 必被恢复。
    private static func runProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 15
    ) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let collector = ProcessOutputCollector()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    collector.markDone(.stdout)
                } else {
                    collector.append(data, to: .stdout)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    collector.markDone(.stderr)
                } else {
                    collector.append(data, to: .stderr)
                }
            }

            process.terminationHandler = { proc in
                collector.markTerminated(status: proc.terminationStatus)
            }

            var watchdog: DispatchWorkItem?
            collector.onComplete = { result in
                watchdog?.cancel()
                continuation.resume(returning: result)
            }

            // 看门狗：先杀进程（正常会触发 EOF/termination 走常规收尾）；
            // 再强制完成兜底（防 EOF 永不出现）；正常路径完成后 cancel 掉
            watchdog = DispatchWorkItem {
                process.terminate()
                collector.forceComplete(status: -1, output: "命令执行超时")
            }
            if let watchdog = watchdog {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            }

            do {
                try process.run()
                // 关掉父进程持有的写端，子进程退出后 pipe 才能到达 EOF，readabilityHandler 才能收到 EOF
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
            } catch {
                watchdog?.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// 同步执行进程（阻塞当前线程，仅供退出路径使用）。
    /// 输出量极小（networksetup / osascript），进程退出后再读到底即可，无 buffer 满风险。
    private static func runProcessSync(executable: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw error
        }
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        return (process.terminationStatus, output)
    }

    // MARK: - 解析 / 转义

    /// 从 networksetup -listallnetworkservices 输出里解析活动服务（排除禁用 `*` 服务与表头）
    private func parseServices(_ output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("An asterisk") }
    }

    /// 单引号包裹（shell 参数转义）
    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 转义后嵌入 AppleScript 双引号字符串（反斜杠 + 双引号）
    private func shellEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// 汇总一次进程执行结果：stdout/stderr 增量累积（锁保护），
/// 等「stdout EOF + stderr EOF + 进程退出」三个条件都满足后回调。
private final class ProcessOutputCollector {
    enum Stream {
        case stdout
        case stderr
    }

    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()
    private var outDone = false
    private var errDone = false
    private var status: Int32?
    var onComplete: (((status: Int32, output: String)) -> Void)?

    func append(_ data: Data, to stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout: outData.append(data)
        case .stderr: errData.append(data)
        }
    }

    func markDone(_ stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout: outDone = true
        case .stderr: errDone = true
        }
        completeIfReady()
    }

    func markTerminated(status: Int32) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
        completeIfReady()
    }

    /// 超时兜底：跳过 EOF 等待，强制按给定结果收尾（若已正常完成则忽略，保证只 resume 一次）
    func forceComplete(status: Int32, output: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let callback = onComplete else { return }
        onComplete = nil
        callback((status, output))
    }

    private func completeIfReady() {
        guard outDone, errDone, let status = status, let callback = onComplete else { return }
        onComplete = nil
        let output = (String(data: outData, encoding: .utf8) ?? "")
            + (String(data: errData, encoding: .utf8) ?? "")
        callback((status, output))
    }
}
