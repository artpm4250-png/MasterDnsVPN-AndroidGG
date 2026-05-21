import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var profile = MasterDNSProfile.empty
    @Published var message = ""
    @Published var showingConfigImporter = false
    @Published var showingResolversImporter = false

    let vpn = VPNController()
    let proxy = LocalProxyController()
    private var cancellables = Set<AnyCancellable>()

    init() {
        vpn.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        proxy.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func refresh() async {
        profile = ProfileStore.load()
        await vpn.load()
    }

    func saveProfile(_ next: MasterDNSProfile) {
        do {
            try ProfileStore.save(next)
            profile = next
            message = "Профиль сохранен"
        } catch {
            message = error.localizedDescription
        }
    }

    func importConfig(from url: URL) {
        do {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            saveProfile(MasterDNSToml.applyingConfig(text, to: profile))
        } catch {
            message = "Не удалось импортировать конфиг"
        }
    }

    func importResolvers(from url: URL) {
        do {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            var next = profile
            next.resolversText = text
            saveProfile(next)
        } catch {
            message = "Не удалось импортировать резолверы"
        }
    }

    func toggleVPN() async {
        do {
            if vpn.status.isActive {
                vpn.stop()
            } else {
                _ = try ProfileStore.loadRequired()
                try await vpn.start()
            }
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func toggleProxy() async {
        if proxy.isRunning {
            proxy.stop()
        } else {
            do {
                let profile = try ProfileStore.loadRequired()
                await proxy.start(profile: profile)
                message = proxy.lastError ?? "Локальный SOCKS запущен"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    statusPanel
                    actionPanel
                    profilePanel
                    diagnosticsPanel
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MasterDnsVPN")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(
            isPresented: $model.showingConfigImporter,
            allowedContentTypes: [.plainText, .text, .data]
        ) { result in
            if case let .success(url) = result { model.importConfig(from: url) }
        }
        .fileImporter(
            isPresented: $model.showingResolversImporter,
            allowedContentTypes: [.plainText, .text, .data]
        ) { result in
            if case let .success(url) = result { model.importResolvers(from: url) }
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(model.vpn.status.isActive ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(model.vpn.status.label)
                    .font(.headline)
                Spacer()
                Text(model.profile.listenAddress)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(model.profile.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(profileStateText)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionPanel: some View {
        VStack(spacing: 10) {
            Button {
                Task { await model.toggleVPN() }
            } label: {
                Text(model.vpn.status.isActive ? "Отключить VPN" : "Включить VPN")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { await model.toggleProxy() }
            } label: {
                Text(model.proxy.isRunning ? "Остановить SOCKS" : "Локальный SOCKS")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var profilePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Профиль")
                .font(.headline)
            HStack(spacing: 10) {
                Button("Импорт TOML") {
                    model.showingConfigImporter = true
                }
                .buttonStyle(.bordered)
                Button("Резолверы") {
                    model.showingResolversImporter = true
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Text("DNS")
                Spacer()
                TextField("8.8.8.8", text: Binding(
                    get: { model.profile.dnsServer },
                    set: {
                        var next = model.profile
                        next.dnsServer = $0
                        model.saveProfile(next)
                    }
                ))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Состояние")
                .font(.headline)
            Text(model.message.isEmpty ? "Готово" : model.message)
                .font(.footnote)
                .foregroundColor(.secondary)
            if let error = model.proxy.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profileStateText: String {
        let hasConfig = !model.profile.clientConfigToml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasResolvers = !model.profile.resolversText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasConfig && hasResolvers { return "Конфиг и резолверы загружены" }
        if hasConfig { return "Нужен список резолверов" }
        return "Импортируй TOML и client_resolvers.txt"
    }
}
