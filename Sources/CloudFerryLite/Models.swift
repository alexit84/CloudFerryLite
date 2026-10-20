import Foundation

enum ConnectionKind: String, Codable, CaseIterable {
    case s3, sftp
}

enum S3AuthMethod: String, Codable, CaseIterable {
    case accessKey, sso
}

enum SFTPAuthMethod: String, Codable, CaseIterable {
    /// Chiavi da ~/.ssh, ssh-agent o IdentityFile indicato.
    case key
    case password
}

/// Una connessione salvata: S3 (AWS o compatibile) oppure SFTP via OpenSSH.
struct Connection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: ConnectionKind = .s3

    // MARK: S3
    /// Vuoto = AWS S3 (s3.<region>.amazonaws.com). Altrimenti es. "https://minio.local:9000".
    var endpoint: String = ""
    var region: String = "us-east-1"
    var usePathStyle: Bool = false
    /// Se false le credenziali non hanno s3:ListAllMyBuckets: si usano i bucket indicati a mano.
    var canListBuckets: Bool = true
    var manualBuckets: [String] = []
    var s3Auth: S3AuthMethod = .accessKey
    var accessKeyID: String = ""
    var ssoStartURL: String = ""
    var ssoRegion: String = ""
    var ssoAccountID: String = ""
    var ssoRoleName: String = ""

    // MARK: SFTP
    /// Host o alias di ~/.ssh/config.
    var host: String = ""
    var port: Int?
    var username: String = ""
    var sftpAuth: SFTPAuthMethod = .key
    var identityFile: String = ""
    /// Cartella iniziale; vuoto = home dell'utente.
    var startPath: String = ""

    static var defaultName: String { String(localized: "New connection") }

    init(name: String, kind: ConnectionKind = .s3) {
        self.name = name
        self.kind = kind
    }

    var isAWS: Bool { endpoint.trimmingCharacters(in: .whitespaces).isEmpty }

    var displayEndpoint: String {
        switch kind {
        case .s3:
            let base = isAWS ? "AWS S3 · \(region)" : endpoint
            return s3Auth == .sso ? base + " · SSO" : base
        case .sftp:
            let user = username.isEmpty ? "" : username + "@"
            return "sftp://\(user)\(host)\(port.map { ":\($0)" } ?? "")"
        }
    }

    var systemImage: String {
        kind == .s3 ? "externaldrive.connected.to.line.below" : "terminal"
    }

    // Decodifica tollerante: le connessioni salvate dalla versione 1 non hanno i campi nuovi.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .s3
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        usePathStyle = try c.decodeIfPresent(Bool.self, forKey: .usePathStyle) ?? false
        canListBuckets = try c.decodeIfPresent(Bool.self, forKey: .canListBuckets) ?? true
        manualBuckets = try c.decodeIfPresent([String].self, forKey: .manualBuckets) ?? []
        s3Auth = try c.decodeIfPresent(S3AuthMethod.self, forKey: .s3Auth) ?? .accessKey
        accessKeyID = try c.decodeIfPresent(String.self, forKey: .accessKeyID) ?? ""
        ssoStartURL = try c.decodeIfPresent(String.self, forKey: .ssoStartURL) ?? ""
        ssoRegion = try c.decodeIfPresent(String.self, forKey: .ssoRegion) ?? ""
        ssoAccountID = try c.decodeIfPresent(String.self, forKey: .ssoAccountID) ?? ""
        ssoRoleName = try c.decodeIfPresent(String.self, forKey: .ssoRoleName) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        sftpAuth = try c.decodeIfPresent(SFTPAuthMethod.self, forKey: .sftpAuth) ?? .key
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        startPath = try c.decodeIfPresent(String.self, forKey: .startPath) ?? ""
    }
}

/// Un preferito: bucket o cartella (prefisso) di una connessione.
struct Favorite: Identifiable, Codable, Hashable {
    var id = UUID()
    var connectionID: UUID
    var bucket: String
    var prefix: String
    var name: String
}

/// Punto di ingresso mostrato in sidebar: un bucket S3 o una cartella radice SFTP.
struct RootEntry: Identifiable, Hashable {
    var name: String
    var bucket: String
    var prefix: String = ""
    var systemImage: String = "shippingbox"
    var id: String { bucket + "|" + prefix }
}

/// Elemento remoto. `key` è la chiave S3 o il path SFTP senza "/" iniziale; le cartelle terminano con "/".
struct RemoteItem: Identifiable, Hashable, Sendable {
    var key: String
    var name: String
    var isFolder: Bool
    var size: Int64 = 0
    var modified: Date?
    var storageClass: String?
    /// Link simbolico (solo SFTP): `isFolder` indica il tipo della destinazione.
    var isSymlink = false

    var id: String { key }

    // Chiavi di ordinamento non opzionali per Table.
    var sizeSort: Int64 { isFolder ? -1 : size }
    var modifiedSort: Date { modified ?? .distantPast }
    var kindSort: String { isFolder ? "" : (name as NSString).pathExtension.lowercased() }

    /// Prefisso della cartella che contiene l'elemento.
    var parentPrefix: String {
        let trimmed = isFolder ? String(key.dropLast()) : key
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }
}

/// Posizione corrente nel browser. Per SFTP `bucket` è sempre "/".
struct BrowseLocation: Hashable {
    var connectionID: UUID
    var bucket: String
    var prefix: String

    /// Componenti del prefisso, es. "a/b/" -> ["a", "b"].
    var segments: [String] { prefix.split(separator: "/").map(String.init) }

    var parent: BrowseLocation? {
        guard !prefix.isEmpty else { return nil }
        var segs = segments
        segs.removeLast()
        return BrowseLocation(connectionID: connectionID, bucket: bucket,
                              prefix: segs.isEmpty ? "" : segs.joined(separator: "/") + "/")
    }

    var title: String { segments.last ?? bucket }
}

enum SidebarItem: Hashable {
    case favorite(UUID)
    case root(UUID, String, String)
}
