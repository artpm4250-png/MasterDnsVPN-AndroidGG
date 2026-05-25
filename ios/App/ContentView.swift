import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppLogEntry: Identifiable, Equatable {
    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"

        var color: Color {
            switch self {
            case .info: return .green
            case .warn: return .orange
            case .error: return .red
            }
        }
    }

    let id = UUID()
    let date: Date
    let level: Level
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var library = ProfileStore.loadLibrary()
    @Published var message = ""
    @Published var showingConfigImporter = false
    @Published var showingResolversImporter = false
    @Published var showingConfigPasteSheet = false
    @Published var showingResolversPasteSheet = false
    @Published var configPasteText = ""
    @Published var resolversPasteText = ""
    @Published var diagnostics: [String] = []
    @Published var selectedTab = 0
    @Published var logs: [AppLogEntry] = []

    let vpn = VPNController()
    let proxy = LocalProxyController()
    private var cancellables = Set<AnyCancellable>()
    private var seenRuntimeLogLines = Set<String>()

    init() {
        vpn.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        proxy.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        append(.info, "Приложение готово")
        Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollRuntimeLogs() }
            .store(in: &cancellables)
    }

    var profile: MasterDNSProfile {
        library.selectedProfile
    }

    func refresh() async {
        library = ProfileStore.loadLibrary()
        await vpn.load()
        proxy.refresh()
        pollRuntimeLogs()
    }

    func saveProfile(_ next: MasterDNSProfile, note: String = "Профиль сохранен", log: Bool = true) {
        do {
            var updated = library
            updated.updateSelected(next)
            try ProfileStore.saveLibrary(updated)
            library = updated
            if log {
                message = note
                append(.info, note)
            }
        } catch {
            message = error.localizedDescription
            append(.error, error.localizedDescription)
        }
    }

    func importConfig(from url: URL) {
        do {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let text = try readTextFile(url)
            importConfigText(text, source: url.lastPathComponent)
        } catch {
            message = "Не удалось импортировать TOML: \(error.localizedDescription)"
            append(.error, message)
        }
    }

    func importConfigText(_ text: String, source: String = "буфер") {
        do {
            let cleaned = try MasterDNSToml.normalizedConfig(text)
            let next = MasterDNSToml.applyingConfig(cleaned, to: profile)
            saveProfile(next, note: "TOML импортирован: \(source)")
        } catch {
            message = error.localizedDescription
            append(.error, message)
        }
    }

    func beginPasteConfig() {
        configPasteText = UIPasteboard.general.string ?? ""
        showingConfigPasteSheet = true
    }

    func finishPasteConfig() {
        importConfigText(configPasteText)
        showingConfigPasteSheet = false
    }

    func selectProfile(_ id: String) {
        var updated = library
        updated.select(id)
        do {
            try ProfileStore.saveLibrary(updated)
            library = updated
            append(.info, "Выбран профиль: \(profile.name)")
        } catch {
            append(.error, error.localizedDescription)
        }
    }

    func addProfile() {
        var updated = library
        updated.addBlankProfile()
        do {
            try ProfileStore.saveLibrary(updated)
            library = updated
            message = "Создан новый профиль"
            append(.info, message)
        } catch {
            append(.error, error.localizedDescription)
        }
    }

    func duplicateProfile() {
        var updated = library
        updated.duplicateSelected()
        do {
            try ProfileStore.saveLibrary(updated)
            library = updated
            message = "Профиль скопирован"
            append(.info, message)
        } catch {
            append(.error, error.localizedDescription)
        }
    }

    func deleteProfile() {
        var updated = library
        let deleted = profile.name
        updated.deleteSelected()
        do {
            try ProfileStore.saveLibrary(updated)
            library = updated
            message = "Профиль удален"
            append(.warn, "Удален профиль: \(deleted)")
        } catch {
            append(.error, error.localizedDescription)
        }
    }

    func importResolvers(from url: URL) {
        do {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let text = try readTextFile(url)
            importResolversText(text, source: url.lastPathComponent)
        } catch {
            message = "Не удалось импортировать резолверы: \(error.localizedDescription)"
            append(.error, message)
        }
    }

    func importResolversText(_ text: String, source: String = "буфер") {
        do {
            let cleaned = try MasterDNSResolvers.normalizedList(text)
            var next = profile
            next.resolversText = cleaned
            saveProfile(next, note: "Резолверы импортированы: \(source)")
        } catch {
            message = error.localizedDescription
            append(.error, message)
        }
    }

    func beginPasteResolvers() {
        resolversPasteText = UIPasteboard.general.string ?? ""
        showingResolversPasteSheet = true
    }

    func finishPasteResolvers() {
        importResolversText(resolversPasteText)
        showingResolversPasteSheet = false
    }

    func toggleVPN() async {
        do {
            if vpn.status.isActive {
                vpn.stop()
                message = "VPN остановлен"
                append(.warn, message)
            } else {
                let clean = try ProfileStore.loadRequired()
                saveProfile(clean, note: "Профиль проверен", log: false)
                try ProfileStore.saveLibrary(library)
                try await vpn.start()
                message = "VPN запускается"
                append(.info, message)
            }
            await refresh()
            if vpn.status.isActive {
                await vpn.refreshProviderState()
            }
        } catch {
            message = error.localizedDescription
            append(.error, message)
        }
    }

    func toggleProxy() async {
        if proxy.isRunning {
            proxy.stop()
            message = "Локальный SOCKS остановлен"
            append(.warn, message)
        } else {
            do {
                try ProfileStore.saveLibrary(library)
                let profile = try ProfileStore.loadRequired()
                await proxy.start(profile: profile)
                message = proxy.lastError ?? "Локальный SOCKS запущен"
                append(proxy.lastError == nil ? .info : .error, message)
            } catch {
                message = error.localizedDescription
                append(.error, message)
            }
        }
    }

    func clearLogs() {
        logs.removeAll()
        append(.info, "Логи очищены")
    }

    func copyProxyAddress() {
        UIPasteboard.general.string = profile.socksURL
        message = "SOCKS-адрес скопирован"
        append(.info, message)
    }

    func copyProfileConfig() {
        UIPasteboard.general.string = profile.clientConfigToml
        message = "TOML скопирован"
        append(.info, message)
    }

    func copyResolvers() {
        UIPasteboard.general.string = profile.resolversText
        message = "Резолверы скопированы"
        append(.info, message)
    }

    func validateProfile() {
        let issues = profile.readinessIssues
        if issues.isEmpty {
            diagnostics = [
                "Профиль готов",
                profile.configSummary,
                "Резолверов: \(profile.resolverCount)",
                "SOCKS: \(profile.socksURL)"
            ]
            message = "Профиль готов к запуску"
            append(.info, message)
        } else {
            diagnostics = issues
            message = "Профиль требует исправлений"
            for issue in issues {
                append(.error, issue)
            }
        }
    }

    func refreshProviderState() async {
        await vpn.refreshProviderState()
        diagnostics = [
            "VPN: \(vpn.status.label)",
            "Extension: \(vpn.providerState)",
            "SOCKS: \(proxy.stateText)"
        ]
        if let error = vpn.lastError {
            append(.error, error)
        }
    }

    func resetVPNProfile() async {
        do {
            try await vpn.resetVPNProfile()
            message = "VPN-профиль iOS сброшен"
            append(.warn, message)
            await vpn.load()
        } catch {
            message = error.localizedDescription
            append(.error, message)
        }
    }

    func append(_ level: AppLogEntry.Level, _ text: String) {
        logs.append(AppLogEntry(date: Date(), level: level, message: text))
        if logs.count > 250 {
            logs.removeFirst(logs.count - 250)
        }
    }

    private func pollRuntimeLogs() {
        for dir in ["packet-tunnel", "local-proxy"] {
            let url = ProfileStore.runtimeURL
                .appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent("client.log")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init).suffix(30)
            for line in lines {
                let key = "\(dir):\(line)"
                guard !seenRuntimeLogLines.contains(key) else { continue }
                seenRuntimeLogLines.insert(key)
                append(parseLogLevel(line), "\(dir): \(line)")
            }
        }
        if seenRuntimeLogLines.count > 500 {
            seenRuntimeLogLines.removeAll(keepingCapacity: true)
        }
    }

    private func parseLogLevel(_ line: String) -> AppLogEntry.Level {
        if line.contains("[ERROR]") { return .error }
        if line.contains("[WARN]") { return .warn }
        return .info
    }

    private func readTextFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let unicode = String(data: data, encoding: .unicode) {
            return unicode
        }
        if let windows = String(data: data, encoding: .windowsCP1251) {
            return windows
        }
        throw NSError(domain: "MasterDnsVPN", code: 20, userInfo: [
            NSLocalizedDescriptionKey: "файл не похож на текстовый UTF-8/TOML"
        ])
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            HomeTab()
                .tabItem { Label("Главная", systemImage: "bolt.horizontal.circle") }
                .tag(0)
            DashboardTab()
                .tabItem { Label("Статус", systemImage: "chart.bar.xaxis") }
                .tag(1)
            ProfileTab()
                .tabItem { Label("Профиль", systemImage: "slider.horizontal.3") }
                .tag(2)
            LogsTab()
                .tabItem { Label("Логи", systemImage: "doc.text.magnifyingglass") }
                .tag(3)
        }
        .accentColor(.teal)
        .fileImporter(
            isPresented: $model.showingConfigImporter,
            allowedContentTypes: [.toml, .plainText, .text, .data, .item]
        ) { result in
            switch result {
            case let .success(url):
                model.importConfig(from: url)
            case let .failure(error):
                model.append(.error, "TOML picker: \(error.localizedDescription)")
            }
        }
        .fileImporter(
            isPresented: $model.showingResolversImporter,
            allowedContentTypes: [.plainText, .text, .data, .item]
        ) { result in
            switch result {
            case let .success(url):
                model.importResolvers(from: url)
            case let .failure(error):
                model.append(.error, "DNS picker: \(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $model.showingConfigPasteSheet) {
            PasteSheet(
                title: "Вставить client_config.toml",
                text: $model.configPasteText,
                actionTitle: "Импортировать TOML"
            ) {
                model.finishPasteConfig()
            }
        }
        .sheet(isPresented: $model.showingResolversPasteSheet) {
            PasteSheet(
                title: "Вставить client_resolvers.txt",
                text: $model.resolversPasteText,
                actionTitle: "Импортировать DNS"
            ) {
                model.finishPasteResolvers()
            }
        }
    }
}

private struct HomeTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    HeaderCard()
                    ProfileCard()
                    QuickActionsCard()
                    RuntimeCard()
                }
                .padding(14)
            }
            .background(AppTheme.background)
            .navigationTitle("MasterDnsVPN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        model.selectedTab = 3
                    } label: {
                        Image(systemName: "doc.text")
                    }
                }
            }
        }
    }
}

private struct PasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var text: String
    let actionTitle: String
    let onImport: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18))
                    )

                Button {
                    onImport()
                } label: {
                    Label(actionTitle, systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
            .background(AppTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                }
            }
        }
    }
}

private struct HeaderCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(AppTheme.gold.opacity(0.18))
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(AppTheme.gold)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text("MasterDnsVPN-GG")
                        .font(.headline)
                    Text(model.vpn.status.label)
                        .font(.subheadline)
                        .foregroundColor(model.vpn.status.isActive ? .green : .secondary)
                }

                Spacer()

                StatusPill(
                    text: model.vpn.status.isActive ? "ВКЛ" : "ВЫКЛ",
                    color: model.vpn.status.isActive ? .green : .secondary
                )
            }
        }
    }
}

private struct ProfileCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppCard {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(profileReady ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.profile.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(profileStateText) · \(model.library.profiles.count) проф.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        model.selectedTab = 2
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    MetricTile(title: "SOCKS", value: model.profile.listenAddress)
                    MetricTile(title: "DNS", value: model.profile.dnsServer)
                }
            }
        }
    }

    private var profileReady: Bool {
        model.profile.isReady
    }

    private var profileStateText: String {
        if profileReady { return "Конфиг и резолверы загружены" }
        if !model.profile.clientConfigToml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Нужен список резолверов"
        }
        return "Импортируй TOML и client_resolvers.txt"
    }
}

private struct QuickActionsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppCard {
            VStack(spacing: 10) {
                Button {
                    Task { await model.toggleVPN() }
                } label: {
                    Label(model.vpn.status.isActive ? "Остановить VPN" : "Запустить VPN", systemImage: model.vpn.status.isActive ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.vpn.status.isActive && !model.profile.isReady)

                HStack(spacing: 10) {
                    Button {
                        Task { await model.toggleProxy() }
                    } label: {
                        Label(model.proxy.isRunning ? "SOCKS стоп" : "SOCKS", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.proxy.isRunning && !model.profile.isReady)

                    Button {
                        model.validateProfile()
                    } label: {
                        Label("Проверить", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Button {
                        model.selectedTab = 2
                    } label: {
                        Label("Профиль", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.copyProxyAddress()
                    } label: {
                        Label("SOCKS URL", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct RuntimeCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Состояние")
                        .font(.headline)
                    Spacer()
                    Text(Date(), style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(model.message.isEmpty ? "Готово" : model.message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("SOCKS: \(model.proxy.stateText)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(model.proxy.statsText)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                Text("Extension: \(model.vpn.providerState)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let error = model.proxy.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }
}

private struct DashboardTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    AppCard {
                        VStack(spacing: 12) {
                            StatRow("VPN", model.vpn.status.label, good: model.vpn.status.isActive)
                            StatRow("Extension", model.vpn.providerState, good: model.vpn.providerState.contains("running"))
                            StatRow("SOCKS", model.proxy.stateText, good: model.proxy.isRunning)
                            StatRow("Адрес", model.profile.listenAddress, good: true)
                            StatRow("Резолверы", "\(model.profile.resolverCount)", good: model.profile.resolverCount > 0)
                        }
                    }
                    AppCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Профиль")
                                .font(.headline)
                            Text(model.profile.name)
                                .font(.subheadline.weight(.semibold))
                            Text("MTU \(model.profile.mtu)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(model.profile.configSummary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    AppCard {
                        VStack(spacing: 10) {
                            Button {
                                Task { await model.refreshProviderState() }
                            } label: {
                                Label("Обновить состояние", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                Task { await model.resetVPNProfile() }
                            } label: {
                                Label("Сбросить VPN-профиль iOS", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    if !model.diagnostics.isEmpty {
                        AppCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Диагностика")
                                    .font(.headline)
                                ForEach(model.diagnostics, id: \.self) { item in
                                    Text(item)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
            }
            .background(AppTheme.background)
            .navigationTitle("Статус")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

}

private struct ProfileTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    AppCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Профили")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    model.addProfile()
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            ForEach(model.library.profiles) { profile in
                                ProfileRow(
                                    profile: profile,
                                    selected: profile.id == model.library.selectedProfileID
                                ) {
                                    model.selectProfile(profile.id)
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    model.duplicateProfile()
                                } label: {
                                    Label("Копия", systemImage: "doc.on.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) {
                                    model.deleteProfile()
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Импорт")
                                .font(.headline)
                            Text("Файлы Android/desktop MasterDnsVPN импортируются как raw TOML без пересборки полей.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            VStack(spacing: 10) {
                                Button {
                                    model.showingConfigImporter = true
                                } label: {
                                    Label("Импортировать client_config.toml", systemImage: "square.and.arrow.down")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    model.beginPasteConfig()
                                } label: {
                                    Label("Вставить TOML из буфера", systemImage: "doc.on.clipboard")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    model.showingResolversImporter = true
                                } label: {
                                    Label("Импортировать client_resolvers.txt", systemImage: "list.bullet.rectangle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    model.beginPasteResolvers()
                                } label: {
                                    Label("Вставить DNS из буфера", systemImage: "doc.plaintext")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    AppCard {
                        VStack(spacing: 12) {
                            EditableField("Название", text: Binding(
                                get: { model.profile.name },
                                set: {
                                    var next = model.profile
                                    next.name = $0
                                    model.saveProfile(next)
                                }
                            ))
                            EditableField("DNS", text: Binding(
                                get: { model.profile.dnsServer },
                                set: {
                                    var next = model.profile
                                    next.dnsServer = $0
                                    model.saveProfile(next)
                                }
                            ))
                            EditableField("SOCKS", text: Binding(
                                get: { model.profile.listenAddress },
                                set: {
                                    var next = model.profile
                                    next.listenAddress = $0
                                    model.saveProfile(next)
                                }
                            ))
                            Stepper("MTU \(model.profile.mtu)", value: Binding(
                                get: { model.profile.mtu },
                                set: {
                                    var next = model.profile
                                    next.mtu = $0
                                    model.saveProfile(next)
                                }
                            ), in: 1200...1500, step: 20)
                        }
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Данные профиля")
                                .font(.headline)
                            Text("TOML: \(model.profile.clientConfigToml.isEmpty ? "нет" : "есть")")
                            Text(model.profile.configSummary)
                            Text("Резолверы: \(model.profile.resolverCount)")
                            Text("SOCKS: \(model.profile.listenAddress)")
                            HStack(spacing: 10) {
                                Button("Копировать SOCKS") { model.copyProxyAddress() }
                                    .buttonStyle(.bordered)
                                Button("Копировать TOML") { model.copyProfileConfig() }
                                    .buttonStyle(.bordered)
                            }
                            Button {
                                model.validateProfile()
                            } label: {
                                Label("Проверить совместимость профиля", systemImage: "checkmark.shield")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Raw TOML")
                                    .font(.headline)
                                Spacer()
                                Button("Проверить") { model.validateProfile() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            Text("Полный конфиг MasterDnsVPN хранится и запускается целиком.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: Binding(
                                get: { model.profile.clientConfigToml },
                                set: {
                                    var next = MasterDNSToml.applyingConfig($0, to: model.profile)
                                    next.clientConfigToml = $0
                                    model.saveProfile(next, note: "TOML обновлен", log: false)
                                }
                            ))
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 220)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Резолверы")
                                    .font(.headline)
                                Spacer()
                                Button("Копировать") { model.copyResolvers() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            TextEditor(text: Binding(
                                get: { model.profile.resolversText },
                                set: {
                                    var next = model.profile
                                    next.resolversText = $0
                                    model.saveProfile(next, note: "Резолверы обновлены", log: false)
                                }
                            ))
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 150)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(14)
            }
            .background(AppTheme.background)
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ProfileRow: View {
    let profile: MasterDNSProfile
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(profile.listenAddress) · \(profile.resolverCount) DNS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(text: profile.isReady ? "ГОТОВ" : "НУЖНА НАСТРОЙКА", color: profile.isReady ? .green : .orange)
            }
            .padding(10)
            .background(selected ? Color.green.opacity(0.08) : Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct LogsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            List {
                if model.logs.isEmpty {
                    Text("Логи появятся после запуска туннеля")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(model.logs.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.level.rawValue)
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(entry.level.color)
                                Text(entry.date, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.message)
                                .font(.footnote)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("Логи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Очистить") {
                        model.clearLogs()
                    }
                }
            }
        }
    }
}

private enum AppTheme {
    static let background = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
    static let gold = Color(red: 0.92, green: 0.68, blue: 0.24)
}

private struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatRow: View {
    let title: String
    let value: String
    let good: Bool

    init(_ title: String, _ value: String, good: Bool) {
        self.title = title
        self.value = value
        self.good = good
    }

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(good ? .green : .orange)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.subheadline)
    }
}

private struct EditableField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            TextField(title, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .font(.subheadline)
    }
}

private extension UTType {
    static var toml: UTType {
        UTType(filenameExtension: "toml") ?? .plainText
    }
}
