import Foundation
import Security

/// Segreti nel Keychain di login: secret key S3, password/passphrase SFTP, token SSO.
enum Keychain {
    private static let service = "io.github.alexit84.CloudFerryLite"

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "CloudFerryLite"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // Segreto principale di una connessione (account = UUID, compatibile con la versione 1).
    static func setSecret(_ secret: String, for id: UUID) { set(secret, account: id.uuidString) }
    static func secret(for id: UUID) -> String? { get(account: id.uuidString) }
    static func deleteSecret(for id: UUID) { delete(account: id.uuidString) }
}

/// Profili letti da ~/.aws/credentials e ~/.aws/config: chiavi statiche o AWS SSO (IAM Identity Center).
struct AWSProfile: Identifiable {
    var name: String
    var accessKeyID: String?
    var secretAccessKey: String?
    var region: String?
    var endpoint: String?
    var ssoStartURL: String?
    var ssoRegion: String?
    var ssoAccountID: String?
    var ssoRoleName: String?
    var id: String { name }

    var isSSO: Bool { ssoStartURL != nil }

    static func load() -> [AWSProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let creds = parseINI(home.appendingPathComponent(".aws/credentials"))
        let raw = parseINI(home.appendingPathComponent(".aws/config"))
        var config: [String: [String: String]] = [:]
        var ssoSessions: [String: [String: String]] = [:]
        for (k, v) in raw {
            if k.hasPrefix("profile ") { config[String(k.dropFirst("profile ".count))] = v }
            else if k.hasPrefix("sso-session ") { ssoSessions[String(k.dropFirst("sso-session ".count))] = v }
            else { config[k] = v }
        }

        var out: [AWSProfile] = []
        for name in Set(creds.keys).union(config.keys) {
            let c = creds[name] ?? [:]
            let cfg = config[name] ?? [:]
            let session = cfg["sso_session"].flatMap { ssoSessions[$0] } ?? [:]
            var p = AWSProfile(name: name,
                               accessKeyID: c["aws_access_key_id"] ?? cfg["aws_access_key_id"],
                               secretAccessKey: c["aws_secret_access_key"] ?? cfg["aws_secret_access_key"],
                               region: c["region"] ?? cfg["region"],
                               endpoint: c["endpoint_url"] ?? cfg["endpoint_url"])
            p.ssoStartURL = session["sso_start_url"] ?? cfg["sso_start_url"]
            p.ssoRegion = session["sso_region"] ?? cfg["sso_region"]
            p.ssoAccountID = cfg["sso_account_id"]
            p.ssoRoleName = cfg["sso_role_name"]
            if p.accessKeyID != nil || p.isSSO { out.append(p) }
        }
        return out.sorted { $0.name < $1.name }
    }

    static func parseINI(_ url: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: [String: String]] = [:]
        var section: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let s = section, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result[s, default: [:]][key] = value
        }
        return result
    }
}
