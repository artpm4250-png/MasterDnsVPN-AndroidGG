import Foundation

enum AppGroup {
    static var identifier: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "group.ru.pasklove.masterdns"
    }
}

struct MasterDNSProfile: Codable, Equatable {
    var name: String
    var clientConfigToml: String
    var resolversText: String
    var listenAddress: String
    var dnsServer: String
    var mtu: Int

    static let empty = MasterDNSProfile(
        name: "MasterDnsVPN",
        clientConfigToml: "",
        resolversText: "",
        listenAddress: "127.0.0.1:10808",
        dnsServer: "8.8.8.8",
        mtu: 1500
    )
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

    static var runtimeURL: URL {
        let url = containerURL.appendingPathComponent("runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load() -> MasterDNSProfile {
        guard let data = try? Data(contentsOf: profileURL),
              let profile = try? JSONDecoder().decode(MasterDNSProfile.self, from: data) else {
            return .empty
        }
        return profile
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
        return MasterDNSProfile(
            name: firstDomain(in: toml) ?? profile.name,
            clientConfigToml: toml,
            resolversText: profile.resolversText,
            listenAddress: "\(listenIP):\(listenPort)",
            dnsServer: profile.dnsServer,
            mtu: profile.mtu
        )
    }

    static func stringValue(_ key: String, in toml: String) -> String? {
        let pattern = #"(?m)^\s*\#(key)\s*=\s*"([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(toml.startIndex..<toml.endIndex, in: toml)
        guard let match = re.firstMatch(in: toml, range: range),
              let valueRange = Range(match.range(at: 1), in: toml) else { return nil }
        return String(toml[valueRange])
    }

    static func intValue(_ key: String, in toml: String) -> Int? {
        let pattern = #"(?m)^\s*\#(key)\s*=\s*([0-9]+)"#
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
