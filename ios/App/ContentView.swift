import Combine
import SwiftUI
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
    @Published var profile = MasterDNSProfile.empty
    @Published var message = ""
    @Published var showingConfigImporter = false
    @Published var showingResolversImporter = false
    @Published var selectedTab = 0
    @Published var logs: [AppLogEntry] = []

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
        append(.info, "Приложение готово")
    }

    func refresh() async {
        profile = ProfileStore.load()
        await vpn.load()
    }

    func saveProfile(_ next: MasterDNSProfile, note: String = "Профиль сохранен") {
        do {
            try ProfileStore.save(next)
            profile = next
            message = note
            append(.info, note)
        } catch {
            message = error.localizedDescription
            append(.error, error.localizedDescription)
        }
    }

    func importConfig(from url: URL) {
        do {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            saveProfile(MasterDNSToml.applyingConfig(text, to: profile), note: "TOML-конфиг импортирован")
        } catch {
            message = "Не удалось импортировать конфиг"
            append(.error, message)
        }
    }

    func importResolvers(from url: URL) {
        do {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            var next = profile
            next.resolversText = text
            saveProfile(next, note: "Резолверы импортированы")
        } catch {
            message = "Не удалось импортировать резолверы"
            append(.error, message)
        }
    }

    func toggleVPN() async {
        do {
            if vpn.status.isActive {
                vpn.stop()
                message = "VPN остановлен"
                append(.warn, message)
            } else {
                _ = try ProfileStore.loadRequired()
                try await vpn.start()
                message = "VPN запускается"
                append(.info, message)
            }
            await refresh()
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

    func append(_ level: AppLogEntry.Level, _ text: String) {
        logs.append(AppLogEntry(date: Date(), level: level, message: text))
        if logs.count > 250 {
            logs.removeFirst(logs.count - 250)
        }
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
                    text: model.vpn.status.isActive ? "ONLINE" : "OFF",
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
                        Text(profileStateText)
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
        !model.profile.clientConfigToml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.profile.resolversText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

                HStack(spacing: 10) {
                    Button {
                        Task { await model.toggleProxy() }
                    } label: {
                        Label(model.proxy.isRunning ? "SOCKS стоп" : "SOCKS", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.showingConfigImporter = true
                    } label: {
                        Label("TOML", systemImage: "square.and.arrow.down")
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
                            StatRow("SOCKS", model.proxy.isRunning ? "Запущен" : "Остановлен", good: model.proxy.isRunning)
                            StatRow("Адрес", model.profile.listenAddress, good: true)
                            StatRow("Резолверы", "\(resolverCount)", good: resolverCount > 0)
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
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .background(AppTheme.background)
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var resolverCount: Int {
        model.profile.resolversText
            .split(whereSeparator: \.isNewline)
            .filter { !String($0).trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}

private struct ProfileTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    AppCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Импорт")
                                .font(.headline)
                            HStack(spacing: 10) {
                                Button("client_config.toml") {
                                    model.showingConfigImporter = true
                                }
                                .buttonStyle(.bordered)
                                Button("client_resolvers.txt") {
                                    model.showingResolversImporter = true
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
                            Text("Резолверы: \(resolverCount)")
                            Text("SOCKS: \(model.profile.listenAddress)")
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .background(AppTheme.background)
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var resolverCount: Int {
        model.profile.resolversText
            .split(whereSeparator: \.isNewline)
            .filter { !String($0).trimmingCharacters(in: .whitespaces).isEmpty }
            .count
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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
