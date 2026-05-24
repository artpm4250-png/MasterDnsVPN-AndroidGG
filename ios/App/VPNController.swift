import Foundation
import NetworkExtension

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var providerState = "не проверен"
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.status = self?.manager?.connection.status ?? .invalid
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load() async {
        do {
            manager = try await loadOrCreateManager()
            status = manager?.connection.status ?? .invalid
            lastError = nil
        } catch {
            status = .invalid
            lastError = error.localizedDescription
        }
    }

    func start() async throws {
        let manager = try await loadOrCreateManager()
        if !manager.isEnabled {
            manager.isEnabled = true
        }
        try await save(manager)
        try await reload(manager)
        try manager.connection.startVPNTunnel()
        self.manager = manager
        status = manager.connection.status
        lastError = nil
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
        status = manager?.connection.status ?? .disconnected
    }

    func resetVPNProfile() async throws {
        let managers = try await loadAllManagers()
        for manager in managers where manager.localizedDescription == "MasterDnsVPN" {
            try await remove(manager)
        }
        manager = nil
        status = .invalid
        providerState = "профиль сброшен"
    }

    func refreshProviderState() async {
        do {
            let manager = try await loadOrCreateManager()
            guard let session = manager.connection as? NETunnelProviderSession,
                  manager.connection.status.isActive else {
                providerState = "extension не запущен"
                return
            }
            let response = try await sendMessage(session, Data("status".utf8))
            providerState = response.flatMap { String(data: $0, encoding: .utf8) } ?? "нет ответа"
            lastError = nil
        } catch {
            providerState = "ошибка"
            lastError = error.localizedDescription
        }
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await loadAllManagers()
        let manager = managers.first { $0.localizedDescription == "MasterDnsVPN" } ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier()
        proto.serverAddress = "MasterDnsVPN"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "MasterDnsVPN"
        manager.isEnabled = true
        self.manager = manager
        return manager
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func remove(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func sendMessage(_ session: NETunnelProviderSession, _ data: Data) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func providerBundleIdentifier() -> String {
        let base = Bundle.main.bundleIdentifier ?? "ru.pasklove.masterdns"
        return "\(base).PacketTunnel"
    }
}

extension NEVPNStatus {
    var label: String {
        switch self {
        case .connected: return "VPN включен"
        case .connecting, .reasserting: return "Подключение"
        case .disconnecting: return "Отключение"
        case .disconnected: return "Отключен"
        case .invalid: return "Не установлен"
        @unknown default: return "Неизвестно"
        }
    }

    var isActive: Bool {
        self == .connected || self == .connecting || self == .reasserting
    }
}
