import Foundation
import Network

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

    var configSummary: String {
        MasterDNSToml.summary(for: clientConfigToml)
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
    static func normalizedConfig(_ toml: String) throws -> String {
        let cleaned = toml
            .replacingOccurrences(of: "\u{feff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw NSError(domain: "MasterDnsVPN", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "TOML пустой"
            ])
        }
        guard firstDomain(in: cleaned) != nil else {
            throw NSError(domain: "MasterDnsVPN", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "В TOML нет DOMAINS"
            ])
        }
        guard let key = stringValue("ENCRYPTION_KEY", in: cleaned), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "MasterDnsVPN", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "В TOML нет ENCRYPTION_KEY"
            ])
        }
        if let method = intValue("DATA_ENCRYPTION_METHOD", in: cleaned), !(0...5).contains(method) {
            throw NSError(domain: "MasterDnsVPN", code: 33, userInfo: [
                NSLocalizedDescriptionKey: "DATA_ENCRYPTION_METHOD должен быть от 0 до 5"
            ])
        }
        if let port = intValue("LISTEN_PORT", in: cleaned), !(0...65535).contains(port) {
            throw NSError(domain: "MasterDnsVPN", code: 34, userInfo: [
                NSLocalizedDescriptionKey: "LISTEN_PORT вне диапазона"
            ])
        }
        if let protocolType = stringValue("PROTOCOL_TYPE", in: cleaned)?.uppercased(),
           protocolType != "SOCKS5" && protocolType != "TCP" {
            throw NSError(domain: "MasterDnsVPN", code: 35, userInfo: [
                NSLocalizedDescriptionKey: "PROTOCOL_TYPE должен быть SOCKS5 или TCP"
            ])
        }
        return cleaned + "\n"
    }

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
        guard let raw = rawValue(key, in: toml) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           let first = trimmed.first,
           let last = trimmed.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func intValue(_ key: String, in toml: String) -> Int? {
        guard let raw = rawValue(key, in: toml) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func firstDomain(in toml: String) -> String? {
        guard let raw = rawValue("DOMAINS", in: toml) else { return nil }
        let pattern = #"["']([^"']+)["']"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = re.firstMatch(in: raw, range: range),
              let valueRange = Range(match.range(at: 1), in: raw) else { return nil }
        return String(raw[valueRange])
    }

    static func summary(for toml: String) -> String {
        guard !toml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "TOML не импортирован"
        }
        let domain = firstDomain(in: toml) ?? "DOMAINS?"
        let listenIP = stringValue("LISTEN_IP", in: toml) ?? "127.0.0.1"
        let listenPort = intValue("LISTEN_PORT", in: toml) ?? 10808
        let protocolType = stringValue("PROTOCOL_TYPE", in: toml) ?? "SOCKS5"
        return "\(domain) · \(protocolType) · \(listenIP):\(listenPort)"
    }

    private static func rawValue(_ key: String, in toml: String) -> String? {
        let prefix = key.uppercased()
        for line in toml.components(separatedBy: .newlines) {
            let stripped = stripInlineComment(line).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let parts = stripped.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let lhs = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard lhs == prefix else { continue }
            return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func stripInlineComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var result = ""
        let singleQuote = UnicodeScalar("'")!
        let doubleQuote = UnicodeScalar("\"")!
        let comment = UnicodeScalar("#")!
        for scalar in line.unicodeScalars {
            if scalar == doubleQuote && !inSingle {
                inDouble.toggle()
            } else if scalar == singleQuote && !inDouble {
                inSingle.toggle()
            } else if scalar == comment && !inSingle && !inDouble {
                break
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

enum MasterDNSResolvers {
    static func normalizedList(_ text: String) throws -> String {
        var valid: [String] = []
        var seen = Set<String>()

        for line in text.components(separatedBy: .newlines) {
            let entry = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            guard isValidResolverEntry(entry) else { continue }
            if seen.insert(entry).inserted {
                valid.append(entry)
            }
        }

        guard !valid.isEmpty else {
            throw NSError(domain: "MasterDnsVPN", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "в списке нет валидных DNS/resolver endpoint"
            ])
        }
        return valid.joined(separator: "\n") + "\n"
    }

    private static func isValidResolverEntry(_ entry: String) -> Bool {
        let hostPart: String
        if entry.hasPrefix("[") {
            guard let end = entry.firstIndex(of: "]") else { return false }
            hostPart = String(entry[entry.index(after: entry.startIndex)..<end])
            let rest = entry[entry.index(after: end)...]
            if !rest.isEmpty {
                guard rest.first == ":" else { return false }
                guard validPort(String(rest.dropFirst())) else { return false }
            }
        } else if let portSplit = splitIPv4HostPort(entry) {
            hostPart = portSplit.host
            guard validPort(portSplit.port) else { return false }
        } else {
            hostPart = entry
        }

        if let slash = hostPart.firstIndex(of: "/") {
            let ip = String(hostPart[..<slash])
            let bits = String(hostPart[hostPart.index(after: slash)...])
            guard let prefix = Int(bits), (0...128).contains(prefix) else { return false }
            return isIPAddress(ip)
        }
        return isIPAddress(hostPart)
    }

    private static func splitIPv4HostPort(_ entry: String) -> (host: String, port: String)? {
        let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func validPort(_ text: String) -> Bool {
        guard let port = Int(text) else { return false }
        return (1...65535).contains(port)
    }

    private static func isIPAddress(_ text: String) -> Bool {
        IPv4Address(text) != nil || IPv6Address(text) != nil
    }
}
