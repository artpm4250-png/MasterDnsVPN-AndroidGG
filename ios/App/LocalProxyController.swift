import Foundation
import MasterDnsVPNCore

@MainActor
final class LocalProxyController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private let instanceID = "local-proxy"

    func start(profile: MasterDNSProfile) async {
        stop()
        lastError = nil
        do {
            let dir = ProfileStore.runtimeURL.appendingPathComponent("local-proxy", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try MobileStartRawInstance(
                instanceID,
                dir.path,
                profile.clientConfigToml,
                profile.resolversText,
                profile.listenAddress
            )
            isRunning = true
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        MobileStopInstance(instanceID)
        isRunning = false
    }
}
