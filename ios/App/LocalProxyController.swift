import Foundation
import MasterDnsVPNCore
import Network

@MainActor
final class LocalProxyController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var stateText = "Остановлен"
    @Published private(set) var statsText = "нет данных"

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
            try await waitForEngineReady(instanceID)
            try await waitForSocks(clean.listenAddress, timeout: 20)
            isRunning = true
            statsText = MobileRuntimeStatus(instanceID)
            stateText = "Подключен: \(clean.listenAddress)"
        } catch {
            lastError = error.localizedDescription
            isRunning = false
            stateText = "Ошибка"
            statsText = MobileRuntimeStatus(instanceID)
            MobileStopInstance(instanceID)
        }
    }

    func stop() {
        MobileStopInstance(instanceID)
        isRunning = false
        stateText = "Остановлен"
        statsText = "нет данных"
    }

    func refresh() {
        isRunning = MobileIsRunning(instanceID)
        statsText = MobileRuntimeStatus(instanceID)
        if isRunning {
            stateText = MobileIsSessionReady(instanceID) ? "Подключен" : "Запуск"
        } else {
            stateText = "Остановлен"
        }
    }

    private func waitForSocks(_ listenAddress: String, timeout: TimeInterval = 90) async throws {
        let parsed = listenAddress.hostPort
        let host = parsed.host == "0.0.0.0" ? "127.0.0.1" : parsed.host
        let port = parsed.port ?? 18000
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await canConnect(host: host, port: port) {
                return
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw NSError(domain: "MasterDnsVPN", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "SOCKS \(host):\(port) не поднялся за \(Int(timeout)) секунд"
        ])
    }

    private func waitForEngineReady(_ instanceID: String) async throws {
        let deadline = Date().addingTimeInterval(90)
        var lastStatus = MobileRuntimeStatus(instanceID)
        while Date() < deadline {
            if !MobileIsRunning(instanceID) {
                let lastError = MobileGetLastError(instanceID)
                throw NSError(domain: "MasterDnsVPN", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: lastError.isEmpty ? "ядро MasterDnsVPN остановилось" : lastError
                ])
            }
            lastStatus = MobileRuntimeStatus(instanceID)
            statsText = lastStatus
            if MobileIsSessionReady(instanceID) && MobileValidResolverCount(instanceID) > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NSError(domain: "MasterDnsVPN", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "туннель не стал готовым за 90 секунд: \(lastStatus)"
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
