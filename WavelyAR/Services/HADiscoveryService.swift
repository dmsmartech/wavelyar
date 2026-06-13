import Foundation
import Network
import Combine

@MainActor
final class HADiscoveryService: ObservableObject {
    static let shared = HADiscoveryService()

    @Published var discoveredInstances: [HADiscoveredInstance] = []
    @Published var isScanning = false

    private var browser: NWBrowser?
    private var tcpScanTask: Task<Void, Never>?

    func startDiscovery() {
        isScanning = true
        discoveredInstances = []
        startMDNSDiscovery()
        startTCPFallback()
    }

    func stopDiscovery() {
        browser?.cancel()
        tcpScanTask?.cancel()
        isScanning = false
    }

    private func startMDNSDiscovery() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_home-assistant._tcp", domain: nil)
        let params = NWParameters()
        browser = NWBrowser(for: descriptor, using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        if case let .bonjour(txtRecord) = result.metadata {
                            let baseURL = txtRecord.dictionary["base_url"] ?? ""
                            let host = self?.extractHost(from: baseURL) ?? name
                            let port = self?.extractPort(from: baseURL) ?? 8123
                            let useTLS = baseURL.hasPrefix("https")
                            let instance = HADiscoveredInstance(name: name, host: host, port: port, useTLS: useTLS)
                            if self?.discoveredInstances.contains(where: { $0.host == host }) == false {
                                self?.discoveredInstances.append(instance)
                            }
                        }
                    }
                }
            }
        }

        browser?.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in self?.isScanning = false }
            }
        }

        browser?.start(queue: .global(qos: .userInitiated))
    }

    private func startTCPFallback() {
        tcpScanTask = Task {
            await scanLocalSubnet()
        }
    }

    private func scanLocalSubnet() async {
        guard let subnet = getLocalSubnet() else { return }
        let semaphore = AsyncSemaphore(limit: 40)
        await withTaskGroup(of: Void.self) { group in
            for i in 1...254 {
                let host = "\(subnet).\(i)"
                group.addTask {
                    await semaphore.wait()
                    await self.checkHost(host, port: 8123)
                    await semaphore.signal()
                }
            }
        }
    }

    private func checkHost(_ host: String, port: Int) async {
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port))!,
                using: .tcp
            )
            var resolved = false
            connection.stateUpdateHandler = { [weak self] state in
                guard !resolved else { return }
                switch state {
                case .ready:
                    resolved = true
                    connection.cancel()
                    Task { @MainActor in
                        if self?.discoveredInstances.contains(where: { $0.host == host }) == false {
                            let instance = HADiscoveredInstance(name: host, host: host, port: port, useTLS: false)
                            self?.discoveredInstances.append(instance)
                        }
                    }
                    continuation.resume()
                case .failed, .cancelled:
                    resolved = true
                    connection.cancel()
                    continuation.resume()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .background))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                guard !resolved else { return }
                resolved = true
                connection.cancel()
                continuation.resume()
            }
        }
    }

    private func getLocalSubnet() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var current = ifaddr
        while let addr = current {
            let name = String(cString: addr.pointee.ifa_name)
            let vpnPrefixes = ["utun", "ipsec"]
            guard name == "en0", !vpnPrefixes.contains(where: { name.hasPrefix($0) }) else {
                current = addr.pointee.ifa_next
                continue
            }
            if addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr.pointee.ifa_addr, socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                let parts = ip.split(separator: ".")
                if parts.count == 4 {
                    return parts.prefix(3).joined(separator: ".")
                }
            }
            current = addr.pointee.ifa_next
        }
        return nil
    }

    private func extractHost(from url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        return u.host
    }

    private func extractPort(from url: String) -> Int {
        guard let u = URL(string: url), let p = u.port else { return 8123 }
        return p
    }
}

private actor AsyncSemaphore {
    private let limit: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func wait() async {
        if count < limit {
            count += 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if waiters.isEmpty {
            count -= 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
