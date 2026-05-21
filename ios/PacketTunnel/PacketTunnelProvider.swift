import Darwin
import Foundation
import MasterDnsVPNCore
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let instanceID = "packet-tunnel"
    private let writerQueue = DispatchQueue(label: "masterdns.packet.writer", qos: .userInitiated)
    private var stopping = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        stopping = false

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
        let state = MobileIsRunning(instanceID) ? "running" : "stopped"
        completionHandler?(state.data(using: .utf8))
    }

    private func startEngine(_ profile: MasterDNSProfile) throws {
        let dir = ProfileStore.runtimeURL.appendingPathComponent("packet-tunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MobileStopInstance(instanceID)
        MobileStopPacketBridge()
        var startError: NSError?
        guard MobileStartRawInstance(
            instanceID,
            dir.path,
            profile.clientConfigToml,
            profile.resolversText,
            profile.listenAddress,
            &startError
        ) else {
            throw startError ?? NSError(domain: "MasterDnsVPN", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Не удалось запустить ядро MasterDnsVPN"
            ])
        }
        Thread.sleep(forTimeInterval: 0.35)
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
        writerQueue.async { [weak self] in
            guard let self else { return }
            while !self.stopping {
                autoreleasepool {
                    guard let packet = MobileReadQueuedPacket(250), !packet.isEmpty else { return }
                    let proto = self.protocolNumber(for: packet)
                    self.packetFlow.writePackets([packet], withProtocols: [proto])
                }
            }
        }
    }

    private func protocolNumber(for packet: Data) -> NSNumber {
        guard let first = packet.first else { return NSNumber(value: AF_INET) }
        return NSNumber(value: (first >> 4) == 6 ? AF_INET6 : AF_INET)
    }
}
