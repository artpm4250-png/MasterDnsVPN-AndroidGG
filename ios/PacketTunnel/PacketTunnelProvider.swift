import Darwin
import Foundation
import MasterDnsVPNCore
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let instanceID = "packet-tunnel"
    private let writerQueue = DispatchQueue(label: "masterdns.packet.writer", qos: .userInitiated)
    private var stopping = false
    private var writerStarted = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        stopping = false
        writerStarted = false

        do {
            let profile = try ProfileStore.loadRequired()
            try startEngine(profile)

            setTunnelNetworkSettings(makeSettings(profile)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.stopEngine()
                    completionHandler(error)
                    return
                }
                self.startPacketReadLoop()
                self.startPacketWriteLoop()
                completionHandler(nil)
            }
        } catch {
            stopEngine()
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stopping = true
        stopEngine()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let running = MobileIsRunning(instanceID)
        let bridge = MobileIsPacketBridgeRunning()
        let state = """
        {"engine":\(running),"bridge":\(bridge),"state":"\(running && bridge ? "running" : "stopped")"}
        """
        completionHandler?(state.data(using: .utf8))
    }

    private func startEngine(_ profile: MasterDNSProfile) throws {
        let dir = ProfileStore.runtimeURL.appendingPathComponent("packet-tunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MobileStopInstance(instanceID)
        MobileStopPacketBridge()
        var startError: NSError?
        let tunnelToml = MasterDNSToml.internalTunnelConfig(profile.clientConfigToml)
        guard MobileStartRawInstance(
            instanceID,
            dir.path,
            tunnelToml,
            profile.resolversText,
            profile.listenAddress,
            &startError
        ) else {
            throw startError ?? NSError(domain: "MasterDnsVPN", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Не удалось запустить ядро MasterDnsVPN"
            ])
        }
        try waitForLocalSocks(profile.listenAddress)
        var bridgeError: NSError?
        guard MobileStartQueuedPacketBridge(Int32(profile.mtu), profile.listenAddress, &bridgeError) else {
            throw bridgeError ?? NSError(domain: "MasterDnsVPN", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Не удалось запустить VPN-мост"
            ])
        }
    }

    private func stopEngine() {
        MobileStopPacketBridge()
        MobileStopInstance(instanceID)
    }

    private func makeSettings(_ profile: MasterDNSProfile) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        settings.mtu = NSNumber(value: profile.mtu)

        let ipv4 = NEIPv4Settings(addresses: ["10.89.0.1"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00:89::1"], networkPrefixLengths: [NSNumber(value: 128)])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: [profile.dnsServer.isEmpty ? "8.8.8.8" : profile.dnsServer])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }

    private func startPacketReadLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, !self.stopping else { return }
            for packet in packets where !packet.isEmpty {
                var injectError: NSError?
                _ = MobileInjectPacket(packet, &injectError)
            }
            self.startPacketReadLoop()
        }
    }

    private func startPacketWriteLoop() {
        guard !writerStarted else { return }
        writerStarted = true
        writerQueue.async { [weak self] in
            guard let self else { return }
            while !self.stopping {
                autoreleasepool {
                    if let packet = MobileReadQueuedPacket(250), !packet.isEmpty {
                        let proto = self.protocolNumber(for: packet)
                        self.packetFlow.writePackets([packet], withProtocols: [proto])
                    }
                }
            }
        }
    }

    private func waitForLocalSocks(_ listenAddress: String) throws {
        let parsed = parseHostPort(listenAddress)
        let host = parsed.host == "0.0.0.0" ? "127.0.0.1" : parsed.host
        let port = parsed.port
        let deadline = Date().addingTimeInterval(8)
        var lastErrno: Int32 = 0
        while Date() < deadline && !stopping {
            if canConnect(host: host, port: port) {
                return
            }
            lastErrno = errno
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw NSError(domain: "MasterDnsVPN", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "SOCKS \(host):\(port) не поднялся за 8 секунд (errno \(lastErrno))"
        ])
    }

    private func parseHostPort(_ value: String) -> (host: String, port: Int) {
        if value.hasPrefix("["),
           let end = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<end])
            let rest = value[value.index(after: end)...]
            if rest.first == ":", let port = Int(rest.dropFirst()) {
                return (host, port)
            }
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) {
            return (String(parts[0]), port)
        }
        return ("127.0.0.1", 18000)
    }

    private func canConnect(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func protocolNumber(for packet: Data) -> NSNumber {
        guard let first = packet.first else { return NSNumber(value: AF_INET) }
        return NSNumber(value: (first >> 4) == 6 ? AF_INET6 : AF_INET)
    }
}


