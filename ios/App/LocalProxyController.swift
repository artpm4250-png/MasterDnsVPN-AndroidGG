import Foundation
import MasterDnsVPNCore
import Network

@MainActor
final class LocalProxyController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var stateText = "Остановлен"

    private let instanceID = "local-proxy"

    func start(profile: MasterDNSProfile) async {
        stop()
        lastError = nil
        stateText = "Запуск"
        do {
            let clean = try ProfileStore.loadRequired()
            let dir = ProfileStore.runtimeURL.appendingPathComponent("local-proxy", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var mobileError: NSError?
            guard MobileStartRawInstance(
                instanceID,
                dir.path,
                clean.clientConfigToml,
                clean.resolversText,
                clean.listenAddress,
                &mobileError
            ) else {
                throw mobileError ?? NSError(domain: "MasterDnsVPN", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Не удалось запустить локальный SOCKS"
                ])
            }
            try await waitForSocks(clean.listenAddress)
            isRunning = true
            stateText = "Запущен: \(clean.listenAddress)"
        } catch {
            lastError = error.localizedDescription
            isRunning = false
            stateText = "Ошибка"
            MobileStopInstance(instanceID)
        }
    }

    func stop() {
        MobileStopInstance(instanceID)
        isRunning = false
        stateText = "Остановлен"
    }

    func refresh() {
        isRunning = MobileIsRunning(instanceID)
        stateText = isRunning ? "Запущен" : "Остановлен"
    }

    private func waitForSocks(_ listenAddress: String) async throws {
        let parsed = listenAddress.hostPort
        let host = parsed.host == "0.0.0.0" ? "127.0.0.1" : parsed.host
        let port = parsed.port ?? 18000
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if await canConnect(host: host, port: port) {
                return
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw NSError(domain: "MasterDnsVPN", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "SOCKS \(host):\(port) не поднялся за 8 секунд"
        ])
    }

    private nonisolated func canConnect(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
            var finished = false
            func finish(_ value: Bool) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                finish(false)
            }
        }
    }
}
