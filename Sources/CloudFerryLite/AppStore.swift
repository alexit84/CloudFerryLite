import Foundation
import Observation

/// Stato persistente: connessioni e preferiti (JSON in Application Support, segreti nel Keychain).
@Observable
@MainActor
final class AppStore {
    var connections: [Connection] = []
    var favorites: [Favorite] = []

    /// Bucket S3 o cartelle radice SFTP per connessione.
    var roots: [UUID: [RootEntry]] = [:]
    var rootErrors: [UUID: String] = [:]
    var loadingRoots: Set<UUID> = []

    let sso = SSOService()

    private var backends: [UUID: any RemoteBackend] = [:]
    private var credentialExpiry: [UUID: Date] = [:]

    private struct Persisted: Codable {
        var connections: [Connection]
        var favorites: [Favorite]
    }

    private static var fileURL: URL {
        // CLOUDFERRYLITE_DATA_DIR: cartella dati alternativa (test), per non toccare quella reale.
        let dir = ProcessInfo.processInfo.environment["CLOUDFERRYLITE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudFerryLite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            connections = p.connections
            favorites = p.favorites
        }
        seedFromEnvironment()
    }

    /// Solo per test: CLOUDFERRYLITE_SEED_ENDPOINT/KEY/SECRET crea una connessione S3 all'avvio,
    /// CLOUDFERRYLITE_SEED_SFTP="host:porta:utente:chiave" una connessione SFTP.
    private func seedFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if let spec = env["CLOUDFERRYLITE_SEED_SFTP"], !connections.contains(where: { $0.kind == .sftp }) {
            let p = spec.split(separator: ":", maxSplits: 3).map(String.init)
            if p.count == 4 {
                var conn = Connection(name: "Seed SFTP \(p[0])", kind: .sftp)
                conn.host = p[0]
                conn.port = Int(p[1])
                conn.username = p[2]
                conn.identityFile = p[3]
                connections.append(conn)
                save()
            }
        }
        guard let ep = env["CLOUDFERRYLITE_SEED_ENDPOINT"], let key = env["CLOUDFERRYLITE_SEED_KEY"],
              let secret = env["CLOUDFERRYLITE_SEED_SECRET"], !connections.contains(where: { $0.endpoint == ep }) else { return }
        var conn = Connection(name: "Seed \(ep)")
        conn.endpoint = ep
        conn.accessKeyID = key
        conn.usePathStyle = true
        Keychain.setSecret(secret, for: conn.id)
        connections.append(conn)
        save()
    }

    private func save() {
        let p = Persisted(connections: connections, favorites: favorites)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(p).write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Connessioni

    func connection(_ id: UUID) -> Connection? { connections.first { $0.id == id } }

    /// `secret`: nil = non modificare, "" = rimuovi (solo SFTP, dove è facoltativo).
    func upsert(_ conn: Connection, secret: String?) {
        if let secret {
            if secret.isEmpty { Keychain.deleteSecret(for: conn.id) } else { Keychain.setSecret(secret, for: conn.id) }
        }
        if let i = connections.firstIndex(where: { $0.id == conn.id }) {
            connections[i] = conn
        } else {
            connections.append(conn)
        }
        resetBackend(conn.id)
        roots[conn.id] = nil
        save()
        Task { await loadRoots(conn.id) }
    }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        favorites.removeAll { $0.connectionID == id }
        roots[id] = nil
        resetBackend(id)
        Keychain.deleteSecret(for: id)
        save()
    }

    private func resetBackend(_ id: UUID) {
        backends[id]?.close()
        backends[id] = nil
        credentialExpiry[id] = nil
    }

    /// Backend pronto all'uso. Per AWS SSO rinnova le credenziali temporanee quando stanno per scadere
    /// (e se serve avvia il login nel browser).
    func backend(for id: UUID) async throws -> any RemoteBackend {
        if let b = backends[id], !(credentialExpiry[id].map { $0.timeIntervalSinceNow < 300 } ?? false) { return b }
        guard let conn = connection(id) else { throw S3Error(status: 0, code: "NoConnection", message: String(localized: "Connection not found")) }
        let backend = try await Self.makeBackend(conn, sso: sso)
        if let s3 = backend as? S3Backend { credentialExpiry[id] = s3.client.credentials.expiration }
        backends[id] = backend
        return backend
    }

    static func makeBackend(_ conn: Connection, sso: SSOService) async throws -> any RemoteBackend {
        switch conn.kind {
        case .sftp:
            return SFTPBackend(connection: conn)
        case .s3:
            let creds: AWSCredentials
            switch conn.s3Auth {
            case .accessKey:
                guard let secret = Keychain.secret(for: conn.id) else {
                    throw S3Error(status: 0, code: "NoSecret", message: String(localized: "Secret key missing from the Keychain: edit the connection"))
                }
                creds = AWSCredentials(accessKeyID: conn.accessKeyID, secretAccessKey: secret)
            case .sso:
                creds = try await sso.roleCredentials(conn)
            }
            return S3Backend(client: S3Client(connection: conn, credentials: creds))
        }
    }

    func loadRoots(_ id: UUID) async {
        guard let conn = connection(id) else { return }
        loadingRoots.insert(id)
        defer { loadingRoots.remove(id) }
        rootErrors[id] = nil
        do {
            roots[id] = try await backend(for: id).roots()
        } catch {
            rootErrors[id] = error.localizedDescription
            roots[id] = conn.kind == .s3 ? conn.manualBuckets.map { RootEntry(name: $0, bucket: $0) } : []
        }
    }

    // MARK: Preferiti

    func favorite(for loc: BrowseLocation) -> Favorite? {
        favorites.first { $0.connectionID == loc.connectionID && $0.bucket == loc.bucket && $0.prefix == loc.prefix }
    }

    func toggleFavorite(_ loc: BrowseLocation) {
        if let f = favorite(for: loc) {
            favorites.removeAll { $0.id == f.id }
        } else {
            favorites.append(Favorite(connectionID: loc.connectionID, bucket: loc.bucket, prefix: loc.prefix, name: loc.title))
        }
        save()
    }

    func renameFavorite(_ id: UUID, to name: String) {
        guard let i = favorites.firstIndex(where: { $0.id == id }) else { return }
        favorites[i].name = name
        save()
    }

    func removeFavorite(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        save()
    }

    func moveFavorites(from: IndexSet, to: Int) {
        favorites.move(fromOffsets: from, toOffset: to)
        save()
    }

    /// Aggiorna i preferiti dopo lo spostamento/rinomina di una cartella.
    func favoritesMoved(connectionID: UUID, bucket: String, fromPrefix: String, toBucket: String, toPrefix: String) {
        var changed = false
        for i in favorites.indices where favorites[i].connectionID == connectionID && favorites[i].bucket == bucket
            && favorites[i].prefix.hasPrefix(fromPrefix) {
            favorites[i].bucket = toBucket
            favorites[i].prefix = toPrefix + favorites[i].prefix.dropFirst(fromPrefix.count)
            changed = true
        }
        if changed { save() }
    }
}
