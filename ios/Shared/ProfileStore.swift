import Foundation

enum AppGroup {
    static var identifier: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "group.ru.pasklove.masterdns"
    }
}

struct MasterDNSProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var clientConfigToml: String
    var resolversText: String
    var listenAddress: String
    var dnsServer: String
    var mtu: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "MasterDnsVPN",
        clientConfigToml: String = "",
        resolversText: String = "",
        listenAddress: String = "127.0.0.1:10808",
        dnsServer: String = "8.8.8.8",
        mtu: Int = 1500,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.clientConfigToml = clientConfigToml
        self.resolversText = resolversText
        self.listenAddress = listenAddress
        self.dnsServer = dnsServer
        self.mtu = mtu
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, clientConfigToml, resolversText, listenAddress, dnsServer, mtu, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "MasterDnsVPN"
        clientConfigToml = try c.decodeIfPresent(String.self, forKey: .clientConfigToml) ?? ""
        resolversText = try c.decodeIfPresent(String.self, forKey: .resolversText) ?? ""
        listenAddress = try c.decodeIfPresent(String.self, forKey: .listenAddress) ?? "127.0.0.1:10808"
        dnsServer = try c.decodeIfPresent(String.self, forKey: .dnsServer) ?? "8.8.8.8"
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu) ?? 1500
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    var isReady: Bool {
        !clientConfigToml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !resolversText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var resolverCount: Int {
        resolversText
            .split(whereSeparator: \.isNewline)
            .filter { !String($0).trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    static let empty = MasterDNSProfile()
}

struct ProfileLibrary: Codable, Equatable {
    var selectedProfileID: String
    var profiles: [MasterDNSProfile]

    static let empty = ProfileLibrary(
        selectedProfileID: MasterDNSProfile.empty.id,
        profiles: [.empty]
    )

    var selectedProfile: MasterDNSProfile {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first ?? .empty
    }

    mutating func select(_ id: String) {
        if profiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
    }

    mutating func updateSelected(_ profile: MasterDNSProfile) {
        var next = profile
        next.updatedAt = Date()
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = next
            selectedProfileID = next.id
        } else {
            profiles.append(next)
            selectedProfileID = next.id
        }
    }

    mutating func addBlankProfile() {
        let count = profiles.count + 1
        let profile = MasterDNSProfile(name: "Профиль \(count)")
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    mutating func duplicateSelected() {
        var copy = selectedProfile
        copy.id = UUID().uuidString
        copy.name += " копия"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        profiles.append(copy)
        selectedProfileID = copy.id
    }

    mutating func deleteSelected() {
        guard profiles.count > 1 else {
            profiles[0] = .empty
            selectedProfileID = profiles[0].id
            return
        }
        profiles.removeAll { $0.id == selectedProfileID }
        selectedProfileID = profiles.first?.id ?? MasterDNSProfile.empty.id
    }
}

enum ProfileStore {
    static var containerURL: URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) {
            return groupURL
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var profileURL: URL {
        containerURL.appendingPathComponent("masterdns-profile.json")
    }

    static var libraryURL: URL {
        containerURL.appendingPathComponent("masterdns-profile-library.json")
    }

    static var runtimeURL: URL {
        let url = containerURL.appendingPathComponent("runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func loadLibrary() -> ProfileLibrary {
        if let data = try? Data(contentsOf: libraryURL),
           let library = try? JSONDecoder().decode(ProfileLibrary.self, from: data),
           !library.profiles.isEmpty {
            return library
        }
        if let data = try? Data(contentsOf: profileURL),
           let profile = try? JSONDecoder().decode(MasterDNSProfile.self, from: data) {
            return ProfileLibrary(selectedProfileID: profile.id, profiles: [profile])
        }
        return .empty
    }

    static func saveLibrary(_ library: ProfileLibrary) throws {
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(library)
        try data.write(to: libraryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let selected = library.profiles.first(where: { $0.id == library.selectedProfileID }) ?? library.profiles.first {
            try save(selected)
        }
    }

    static func load() -> MasterDNSProfile {
        loadLibrary().selectedProfile
    }

    static func loadRequired() throws -> MasterDNSProfile {
        let profile = load()
        if profile.clientConfigToml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "MasterDnsVPN", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Профиль не импортирован"
            ])
        }
        if profile.resolversText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "MasterDnsVPN", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Список DNS-резолверов пуст"
            ])
        }
        return profile
    }

    static func save(_ profile: MasterDNSProfile) throws {
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: profileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum MasterDNSToml {
    static func applyingConfig(_ toml: String, to profile: MasterDNSProfile) -> MasterDNSProfile {
        let listenIP = stringValue("LISTEN_IP", in: toml) ?? "127.0.0.1"
        let listenPort = intValue("LISTEN_PORT", in: toml) ?? 10808
        var next = profile
        next.name = firstDomain(in: toml) ?? profile.name
        next.clientConfigToml = toml
        next.listenAddress = "\(listenIP):\(listenPort)"
        next.updatedAt = Date()
        return next
    }

    static func stringValue(_ key: String, in toml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(?m)^\s*\#(escaped)\s*=\s*"([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(toml.startIndex..<toml.endIndex, in: toml)
        guard let match = re.firstMatch(in: toml, range: range),
              let valueRange = Range(match.range(at: 1), in: toml) else { return nil }
        return String(toml[valueRange])
    }

    static func intValue(_ key: String, in toml: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(?m)^\s*\#(escaped)\s*=\s*([0-9]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(toml.startIndex..<toml.endIndex, in: toml)
        guard let match = re.firstMatch(in: toml, range: range),
              let valueRange = Range(match.range(at: 1), in: toml) else { return nil }
        return Int(String(toml[valueRange]))
    }

    static func firstDomain(in toml: String) -> String? {
        let pattern = #"(?m)^\s*DOMAINS\s*=\s*\[\s*"([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(toml.startIndex..<toml.endIndex, in: toml)
        guard let match = re.firstMatch(in: toml, range: range),
              let valueRange = Range(match.range(at: 1), in: toml) else { return nil }
        return String(toml[valueRange])
    }
}
