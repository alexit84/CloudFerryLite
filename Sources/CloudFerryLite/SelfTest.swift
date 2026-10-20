import Foundation

/// End-to-end tests of the backends against real servers, without UI.
/// S3:   CLOUDFERRYLITE_SELFTEST=1 S3_ENDPOINT=http://localhost:9000 S3_KEY=... S3_SECRET=... CloudFerryLite
/// SFTP: CLOUDFERRYLITE_SELFTEST=1 SFTP_HOST=localhost SFTP_PORT=2222 SFTP_USER=foo [SFTP_KEY=path | SFTP_PASSWORD=...] CloudFerryLite
enum SelfTest {
    @MainActor
    static func run() async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        var failed = false
        if env["S3_ENDPOINT"] != nil { failed = await (runS3(env) != 0) || failed }
        if env["SFTP_HOST"] != nil { failed = await (runSFTP(env) != 0) || failed }
        return failed ? 1 : 0
    }

    private static func log(_ s: String) { print("[selftest] " + s) }

    @MainActor
    private static func runS3(_ env: [String: String]) async -> Int32 {
        var conn = Connection(name: "selftest-s3")
        conn.endpoint = env["S3_ENDPOINT"]!
        conn.region = env["S3_REGION"] ?? "us-east-1"
        conn.accessKeyID = env["S3_KEY"] ?? ""
        conn.usePathStyle = true
        let client = S3Client(connection: conn, credentials: AWSCredentials(accessKeyID: conn.accessKeyID,
                                                                             secretAccessKey: env["S3_SECRET"] ?? ""))
        let bucket = "cloudferrylite-selftest"
        do {
            var req = client.makeRequest("PUT", bucket: bucket, payloadHash: S3Client.emptySHA256)
            req.httpBody = Data()
            _ = try await client.session.data(for: req)
            let backend = S3Backend(client: client)
            log("S3 roots: \(try await backend.roots().map(\.name))")
            try await suite(backend, conn: conn, bucket: bucket, env: env)

            // Presigned link: must work without credentials.
            let text = "hello presigned"
            try await backend.upload(file: try tempFile(text), size: Int64(text.utf8.count), bucket: bucket, key: "p.txt") { _ in }
            let url = client.presignedURL(bucket: bucket, key: "p.txt", expires: 600)
            let (data, resp) = try await URLSession.shared.data(from: url)
            log("presigned GET: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) body=\(String(decoding: data, as: UTF8.self))")
            try await backend.delete(bucket: bucket, items: [RemoteItem(key: "p.txt", name: "p.txt", isFolder: false)])

            // Replacing a folder: the old contents of the destination must not remain.
            for (k, t) in [("e/x/1.txt", "1"), ("e/y/2.txt", "2")] {
                try await backend.upload(file: try tempFile(t), size: 1, bucket: bucket, key: k) { _ in }
            }
            try await backend.move(bucket: bucket, item: RemoteItem(key: "e/x/", name: "x", isFolder: true), toBucket: bucket,
                                   toKey: "e/y/", replace: true) { _ in }
            log("S3 replace folder: \(try await backend.listAll(bucket: bucket, prefix: "e/").map(\.key).sorted())")
            do {
                try await backend.move(bucket: bucket, item: RemoteItem(key: "e/y/", name: "y", isFolder: true), toBucket: bucket,
                                       toKey: "e/", replace: true) { _ in }
                log("S3 ancestor guard: NO ERROR (wrong)")
            } catch {
                log("S3 ancestor guard: expected error → \(error.localizedDescription)")
            }
            try await backend.delete(bucket: bucket, items: [RemoteItem(key: "e/", name: "e", isFolder: true)])
            return 0
        } catch {
            log("S3 FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    @MainActor
    private static func runSFTP(_ env: [String: String]) async -> Int32 {
        var conn = Connection(name: "selftest-sftp", kind: .sftp)
        conn.host = env["SFTP_HOST"]!
        conn.port = env["SFTP_PORT"].flatMap(Int.init)
        conn.username = env["SFTP_USER"] ?? ""
        if let key = env["SFTP_KEY"] { conn.identityFile = key }
        if let pw = env["SFTP_PASSWORD"] {
            conn.sftpAuth = .password
            Keychain.setSecret(pw, for: conn.id)
        }
        defer { Keychain.deleteSecret(for: conn.id) }
        // Tests only: the host key of the throwaway container is not saved in known_hosts.
        let backend = SFTPBackend(connection: conn, extraOptions: env["SFTP_STRICT"] == "1" ? (env["SFTP_EXTRA"]?.split(separator: " ").map(String.init) ?? []) : ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"])
        defer { backend.close() }
        do {
            let roots = try await backend.roots()
            log("SFTP roots: \(roots.map { "\($0.name)=/\($0.prefix)" })")
            let base = env["SFTP_BASE"] ?? (roots.first { $0.systemImage == "house" }?.prefix ?? "")
            try await suite(backend, conn: conn, bucket: "/", base: base, env: env)
            try await sftpEdgeCases(backend, conn: conn, base: base)
            return 0
        } catch {
            log("SFTP FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    /// Symbolic links (loops, links to outside folders) and replacing the destination when moving.
    @MainActor
    private static func sftpEdgeCases(_ backend: SFTPBackend, conn: Connection, base: String) async throws {
        let root = base + "bl-edge/"
        let loc = BrowseLocation(connectionID: conn.id, bucket: "/", prefix: root)
        func put(_ key: String, _ text: String) async throws {
            let f = try tempFile(text)
            try await backend.upload(file: f, size: Int64(text.utf8.count), bucket: "/", key: root + key) { _ in }
        }
        func item(_ key: String, folder: Bool = false, link: Bool = false) -> RemoteItem {
            RemoteItem(key: root + key + (folder ? "/" : ""), name: (key as NSString).lastPathComponent, isFolder: folder, isSymlink: link)
        }
        func names() async throws -> [String] {
            try await backend.listAll(bucket: "/", prefix: root).map { String($0.key.dropFirst(root.count)) }.sorted()
        }
        try? await backend.delete(bucket: "/", items: [RemoteItem(key: root, name: "bl-edge", isFolder: true)])
        try await backend.createFolder(bucket: "/", key: root)

        // Links: dir/loop -> dir (loop), dir/toReal -> real (outside folder).
        try await put("real/f.txt", "real content")
        try await backend.createFolder(bucket: "/", key: root + "dir/")
        try await put("dir/g.txt", "g")
        try await backend.makeSymlink(target: "/" + root + "dir", linkKey: root + "dir/loop")
        try await backend.makeSymlink(target: "/" + root + "real", linkKey: root + "dir/toReal")
        let listing = try await backend.listPage(bucket: "/", prefix: root + "dir/", token: nil).items
        log("SFTP links seen: \(listing.map { "\($0.name) link=\($0.isSymlink) folder=\($0.isFolder)" }.sorted())")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bl-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let tm = TransferManager()
        tm.download([item("dir", folder: true)], from: loc, backend: backend, to: tmp)
        try await waitAll(tm)
        let got = FileManager.default.enumerator(atPath: tmp.path)?.allObjects.compactMap { $0 as? String }.sorted() ?? []
        log("SFTP download with links (loop skipped, link followed): \(got)")

        tm.items.removeAll()
        tm.delete([item("dir", folder: true)], from: loc, backend: backend)
        try await waitAll(tm)
        log("SFTP after deleting dir (real/f.txt must remain): \(try await names())")

        // Replace a file.
        try await put("a.txt", "A")
        try await put("b.txt", "B")
        do {
            try await backend.move(bucket: "/", item: item("a.txt"), toBucket: "/", toKey: root + "b.txt", replace: false) { _ in }
            log("SFTP move onto existing without replace: NO ERROR (wrong)")
        } catch {
            log("SFTP move onto existing without replace: expected error → \(error.localizedDescription)")
        }
        try await backend.move(bucket: "/", item: item("a.txt"), toBucket: "/", toKey: root + "b.txt", replace: true) { _ in }
        let check = tmp.appendingPathComponent("b-check.txt")
        try await backend.download(bucket: "/", key: root + "b.txt", size: 1, to: check) { _ in }
        log("SFTP replace file: b.txt = \"\(try String(contentsOf: check, encoding: .utf8))\", a.txt present: \(try await names().contains("a.txt"))")

        // Replace a folder.
        try await put("x/1.txt", "1")
        try await put("y/2.txt", "2")
        try await backend.move(bucket: "/", item: item("x", folder: true), toBucket: "/", toKey: root + "y/", replace: true) { _ in }
        log("SFTP replace folder: \(try await names())")

        // Guard: the destination contains the source.
        try await put("p/p/z.txt", "z")
        do {
            try await backend.move(bucket: "/", item: item("p/p", folder: true), toBucket: "/", toKey: root + "p/", replace: true) { _ in }
            log("SFTP ancestor guard: NO ERROR (wrong)")
        } catch {
            log("SFTP ancestor guard: expected error → \(error.localizedDescription); p/p/z.txt present: \(try await names().contains("p/p/z.txt"))")
        }

        try await backend.delete(bucket: "/", items: [RemoteItem(key: root, name: "bl-edge", isFolder: true)])
    }

    private static func tempFile(_ content: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bl-\(UUID().uuidString).txt")
        try Data(content.utf8).write(to: u)
        return u
    }

    /// Folder + large file upload, listing, download and comparison, rename, move, delete.
    @MainActor
    private static func suite(_ backend: any RemoteBackend, conn: Connection, bucket: String, base: String = "",
                              env: [String: String]) async throws {
        let tag = conn.kind == .s3 ? "S3" : "SFTP"
        let tm = TransferManager()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cloudferrylite-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = BrowseLocation(connectionID: conn.id, bucket: bucket, prefix: base + "bl-test/")
        try? await backend.delete(bucket: bucket, items: [RemoteItem(key: root.prefix, name: "bl-test", isFolder: true)])
        try await backend.createFolder(bucket: bucket, key: root.prefix)

        let src = tmp.appendingPathComponent("Test folder")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub dir/àccènti"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data("file + symbols".utf8).write(to: src.appendingPathComponent("sub dir/b&c (1).txt"))
        try Data("x".utf8).write(to: src.appendingPathComponent("sub dir/àccènti/é.txt"))
        let big = tmp.appendingPathComponent("big.bin")
        try Data((0..<(70 * 1024 * 1024)).map { UInt8($0 % 251) }).write(to: big)

        var start = Date()
        tm.upload([src, big], to: root, backend: backend)
        try await waitAll(tm)
        log("\(tag) upload: \(String(format: "%.1f", Date().timeIntervalSince(start))) s")

        let page = try await backend.listPage(bucket: bucket, prefix: root.prefix, token: nil)
        log("\(tag) listing: \(page.items.map { $0.isFolder ? $0.name + "/" : "\($0.name) (\($0.size))" }.sorted())")

        let dest = tmp.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        start = Date()
        tm.items.removeAll()
        tm.download(page.items.filter { $0.name == "Test folder" || $0.name == "big.bin" }, from: root, backend: backend, to: dest)
        try await waitAll(tm)
        log("\(tag) download: \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        for rel in ["Test folder/a.txt", "Test folder/sub dir/b&c (1).txt", "Test folder/sub dir/àccènti/é.txt", "big.bin"] {
            let a = try Data(contentsOf: tmp.appendingPathComponent(rel))
            let b = try Data(contentsOf: dest.appendingPathComponent(rel))
            log("\(tag) compare \(rel): \(a == b ? "OK" : "DIFF")")
        }

        // Rename a file and a folder, then move the folder into another one.
        let folder = page.items.first { $0.name == "Test folder" }!
        let file = page.items.first { $0.name == "big.bin" }!
        tm.items.removeAll()
        tm.move([(file, root.prefix + "large.bin"), (folder, root.prefix + "Renamed/")], from: root, toBucket: bucket,
                backend: backend, title: "rename")
        try await waitAll(tm)
        try await backend.createFolder(bucket: bucket, key: root.prefix + "Destination/")
        let renamed = RemoteItem(key: root.prefix + "Renamed/", name: "Renamed", isFolder: true)
        tm.items.removeAll()
        tm.move([(renamed, root.prefix + "Destination/Renamed/")], from: root, toBucket: bucket, backend: backend, title: "move")
        try await waitAll(tm)
        let after = try await backend.listAll(bucket: bucket, prefix: root.prefix).map { String($0.key.dropFirst(root.prefix.count)) }.sorted()
        log("\(tag) after rename + move: \(after)")

        if env["KEEP"] == "1" { log("\(tag) KEEP=1: data left in \(root.prefix)"); return }
        tm.items.removeAll()
        tm.delete([RemoteItem(key: root.prefix, name: "bl-test", isFolder: true)], from: root, backend: backend)
        try await waitAll(tm)
        let left = try? await backend.listPage(bucket: bucket, prefix: base, token: nil)
        log("\(tag) after delete, bl-test present: \(left?.items.contains { $0.name == "bl-test" } ?? false)")
    }

    @MainActor
    private static func waitAll(_ tm: TransferManager) async throws {
        while tm.activeCount > 0 { try await Task.sleep(for: .milliseconds(100)) }
        for i in tm.items {
            if case .failed(let m) = i.state { throw S3Error(status: 0, code: "TransferFailed", message: "\(i.title): \(m)") }
        }
    }
}
