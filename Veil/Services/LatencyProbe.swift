import Foundation
import Darwin

/// 通过 TCP 连接测量到「主机:端口」的直连时延（毫秒），即节点「ping」。
/// 用 POSIX socket 直连，绕过系统代理（HTTP/SOCKS）：连接后系统代理指向本地 mihomo，
/// 若走 NWConnection 会测到本地代理端口（几毫秒）而非真实节点，这里改直连保证测的是真实时延。
/// 阻塞式 connect 放到后台队列执行，不阻塞任何线程（含主线程）。
enum LatencyProbe {
    /// 默认连接超时（秒）
    static let connectTimeout: TimeInterval = 3

    /// 测一次 TCP 连接耗时（毫秒）；失败或超时返回 nil
    static func tcpLatency(host: String, port: Int, timeout: TimeInterval = connectTimeout) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            measure(host: host, port: port, timeout: timeout)
        }.value
    }

    // MARK: - 直连测量（后台线程）

    private static func measure(host: String, port: Int, timeout: TimeInterval) -> Int? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, info != nil else { return nil }
        defer { freeaddrinfo(info) }

        let start = DispatchTime.now()
        var result: Int? = nil
        var current = info
        while let addr = current {
            let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if fd >= 0 {
                if connectWithTimeout(fd, addr: addr.pointee.ai_addr, len: addr.pointee.ai_addrlen, timeout: timeout) {
                    result = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                    close(fd)
                    break
                }
                close(fd)
            }
            current = addr.pointee.ai_next
        }
        return result
    }

    /// 非阻塞 connect + poll 超时；就绪后再用 SO_ERROR 确认连接真的建立（避免连接被拒时误判成功）
    private static func connectWithTimeout(_ fd: Int32, addr: UnsafePointer<sockaddr>?, len: socklen_t, timeout: TimeInterval) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let ret = connect(fd, addr, len)
        if ret == 0 { return true }

        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }

        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        return soError == 0
    }
}
