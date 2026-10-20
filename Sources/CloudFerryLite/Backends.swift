import Foundation

struct ListPage {
    var items: [RemoteItem]
    var nextToken: String?
}

/// Operations shared by S3 and SFTP. For SFTP `bucket` is always "/" and keys are paths without the leading "/".
protocol RemoteBackend: AnyObject, Sendable {
    func roots() async throws -> [RootEntry]
    /// Direct contents of a folder (one page).
    func listPage(bucket: String, prefix: String, token: String?) async throws -> ListPage
    /// Everything under a prefix, recursively; folders have keys ending with "/".
    func listAll(bucket: String, prefix: String) async throws -> [RemoteItem]
    func download(bucket: String, key: String, size: Int64, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    func upload(file: URL, size: Int64, bucket: String, key: String, progress: @escaping @Sendable (Int64) -> Void) async throws
    func createFolder(bucket: String, key: String) async throws
    /// Deletes files and folders (with all their contents).
    func delete(bucket: String, items: [RemoteItem]) async throws
    /// Moves or renames a file or folder; for folders `toKey` ends with "/".
    /// `replace`: replaces an existing destination (otherwise SFTP fails and S3 overwrites the files).
    func move(bucket: String, item: RemoteItem, toBucket: String, toKey: String, replace: Bool,
              progress: @escaping @Sendable (Int64) -> Void) async throws
    func close()
}

// MARK: - S3

final class S3Backend: RemoteBackend, @unchecked Sendable {
    let client: S3Client
    static let multipartThreshold: Int64 = 64 * 1024 * 1024

    init(client: S3Client) { self.client = client }

    func roots() async throws -> [RootEntry] {
        let conn = client.connection
        var names: [String]
        if conn.canListBuckets {
            names = try await client.listBuckets()
        } else {
            names = conn.manualBuckets
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return names.map { RootEntry(name: $0, bucket: $0) }
    }

    func listPage(bucket: String, prefix: String, token: String?) async throws -> ListPage {
        let page = try await client.listPage(bucket: bucket, prefix: prefix, delimiter: "/", token: token)
        return ListPage(items: page.items, nextToken: page.nextToken)
    }

    func listAll(bucket: String, prefix: String) async throws -> [RemoteItem] {
        try await client.listAll(bucket: bucket, prefix: prefix)
    }

    func download(bucket: String, key: String, size: Int64, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let req = client.downloadRequest(bucket: bucket, key: key)
        let (tmp, resp) = try await client.session.download(for: req, delegate: ProgressDelegate(progress))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = try? Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            try S3Client.check(resp, body: body)
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    func upload(file: URL, size: Int64, bucket: String, key: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if size >= Self.multipartThreshold {
            try await multipartUpload(file, size: size, key: key, bucket: bucket, progress: progress)
        } else {
            let req = client.uploadRequest(bucket: bucket, key: key, contentType: file.mimeType)
            let (data, resp) = try await client.session.upload(for: req, fromFile: file, delegate: ProgressDelegate(progress))
            try S3Client.check(resp, body: data)
        }
    }

    private func multipartUpload(_ url: URL, size: Int64, key: String, bucket: String,
                                 progress: @escaping @Sendable (Int64) -> Void) async throws {
        // At most 10,000 parts: parts of at least 16 MB.
        let partSize = max(Int64(16 * 1024 * 1024), (size + 9_999) / 10_000)
        let uploadID = try await client.createMultipartUpload(bucket: bucket, key: key, contentType: url.mimeType)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var etags: [String] = []
            var offset: Int64 = 0
            var part = 1
            while offset < size {
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64(offset))
                let chunk = handle.readData(ofLength: Int(min(partSize, size - offset)))
                let base = offset
                let req = client.uploadPartRequest(bucket: bucket, key: key, uploadID: uploadID, partNumber: part)
                let (data, resp) = try await client.session.upload(for: req, from: chunk,
                                                                   delegate: ProgressDelegate { progress(base + $0) })
                try S3Client.check(resp, body: data)
                guard let etag = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") else {
                    throw S3Error(status: 0, code: "NoETag", message: String(localized: "Missing ETag for part \(part)"))
                }
                etags.append(etag)
                offset += Int64(chunk.count)
                part += 1
            }
            try await client.completeMultipartUpload(bucket: bucket, key: key, uploadID: uploadID, etags: etags)
        } catch {
            await client.abortMultipartUpload(bucket: bucket, key: key, uploadID: uploadID)
            throw error
        }
    }

    func createFolder(bucket: String, key: String) async throws {
        try await client.createFolder(bucket: bucket, key: key)
    }

    func delete(bucket: String, items: [RemoteItem]) async throws {
        var keys: [String] = []
        for item in items {
            if item.isFolder {
                keys += try await client.listAll(bucket: bucket, prefix: item.key).map(\.key)
            }
            keys.append(item.key) // file, or folder marker
        }
        try await client.deleteObjects(bucket: bucket, keys: Array(Set(keys)))
    }

    func move(bucket: String, item: RemoteItem, toBucket: String, toKey: String, replace: Bool,
              progress: @escaping @Sendable (Int64) -> Void) async throws {
        try MoveCheck.validate(item: item, fromBucket: bucket, toBucket: toBucket, toKey: toKey)
        // Replacing a folder means emptying it first, otherwise stale files would remain.
        if replace && item.isFolder {
            let old = try await client.listAll(bucket: toBucket, prefix: toKey).map(\.key)
            if !old.isEmpty { try await client.deleteObjects(bucket: toBucket, keys: old + [toKey]) }
        }
        // S3 has no rename: copy every object, then delete the originals.
        var objects: [(key: String, size: Int64)] = []
        if item.isFolder {
            objects = try await client.listAll(bucket: bucket, prefix: item.key).map { ($0.key, $0.size) }
            // Empty folder without a marker: create the destination anyway.
            if objects.isEmpty { try await client.createFolder(bucket: toBucket, key: toKey) }
        } else {
            objects = [(item.key, item.size)]
        }
        let done = ByteCounter()
        try await TransferManager.forEachConcurrently(objects, limit: 8) { obj in
            let dest = toKey + obj.key.dropFirst(item.isFolder ? item.key.count : obj.key.count)
            try await self.client.copyObject(fromBucket: bucket, key: obj.key, size: obj.size, toBucket: toBucket, toKey: dest)
            progress(done.add(obj.size))
        }
        try await client.deleteObjects(bucket: bucket, keys: objects.map(\.key))
    }

    func close() {}
}

// MARK: - SFTP

final class SFTPBackend: RemoteBackend, @unchecked Sendable {
    let connection: Connection
    private let extraOptions: [String]
    private let lock = NSLock()
    private var session: SFTPSession?
    private var connecting: Task<SFTPSession, Error>?

    init(connection: Connection, extraOptions: [String] = []) {
        self.connection = connection
        self.extraOptions = extraOptions
    }

    /// Active session, reconnecting if ssh has exited. Concurrent callers share the same connection attempt.
    func sftp() async throws -> SFTPSession {
        let task: Task<SFTPSession, Error> = lock.withLock {
            if let s = session, s.isAlive { return Task { s } }
            if let c = connecting { return c }
            let conn = connection, extra = extraOptions
            let t = Task { try await SFTPSession.connect(conn, extraOptions: extra) }
            connecting = t
            return t
        }
        do {
            let s = try await task.value
            lock.withLock { session = s; connecting = nil }
            return s
        } catch {
            lock.withLock { connecting = nil }
            throw error
        }
    }

    private static func path(_ key: String) -> String {
        "/" + (key.hasSuffix("/") ? String(key.dropLast()) : key)
    }

    private static func key(fromPath path: String, isFolder: Bool) -> String {
        var k = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if isFolder && !k.isEmpty && !k.hasSuffix("/") { k += "/" }
        return k
    }

    func roots() async throws -> [RootEntry] {
        let s = try await sftp()
        var out: [RootEntry] = []
        if !connection.startPath.isEmpty {
            let p = try await s.realpath(connection.startPath)
            out.append(RootEntry(name: (p as NSString).lastPathComponent.isEmpty ? p : (p as NSString).lastPathComponent,
                                 bucket: "/", prefix: Self.key(fromPath: p, isFolder: true), systemImage: "folder"))
        }
        let home = try await s.realpath(".")
        out.append(RootEntry(name: String(localized: "Home"), bucket: "/", prefix: Self.key(fromPath: home, isFolder: true), systemImage: "house"))
        out.append(RootEntry(name: "/", bucket: "/", prefix: "", systemImage: "internaldrive"))
        // With home = "/" (e.g. a chroot server) the roots coincide: keep the first of each.
        var seen = Set<String>()
        return out.filter { seen.insert($0.prefix).inserted }
    }

    func listPage(bucket: String, prefix: String, token: String?) async throws -> ListPage {
        ListPage(items: try await listDirectory(prefix), nextToken: nil)
    }

    private func listDirectory(_ prefix: String) async throws -> [RemoteItem] {
        let s = try await sftp()
        let dir = prefix.isEmpty ? "/" : Self.path(prefix)
        var items: [RemoteItem] = []
        for entry in try await s.listDirectory(dir) {
            var attrs = entry.attrs
            let link = attrs.isSymlink
            // For links, show the kind and size of the target (when reachable).
            if link, let target = try? await s.stat(dir + "/" + entry.name) { attrs = target }
            let folder = attrs.isDirectory
            items.append(RemoteItem(key: prefix + entry.name + (folder ? "/" : ""), name: entry.name, isFolder: folder,
                                    size: attrs.size ?? 0, modified: attrs.mtime, isSymlink: link))
        }
        return items
    }

    /// Downloads and copies: follows symbolic links to folders, skipping those that lead back to folders already visited.
    func listAll(bucket: String, prefix: String) async throws -> [RemoteItem] {
        try await walk(prefix, followLinks: true)
    }

    /// Recursive walk. With `followLinks` = false, links to folders are returned as leaves (not entered).
    private func walk(_ prefix: String, followLinks: Bool) async throws -> [RemoteItem] {
        let s = try await sftp()
        var out: [RemoteItem] = []
        let rootReal = try await s.realpath(prefix.isEmpty ? "/" : Self.path(prefix))
        var visited: Set<String> = [rootReal]
        var queue = [(key: prefix, real: rootReal)]
        while let dir = queue.popLast() {
            try Task.checkCancellation()
            for item in try await listDirectory(dir.key) {
                guard item.isFolder else { out.append(item); continue }
                if item.isSymlink {
                    guard followLinks else { out.append(item); continue }
                    // A link to an ancestor or an already visited folder would create a loop: skip it.
                    guard let real = try? await s.realpath(Self.path(item.key)), !visited.contains(real) else { continue }
                    visited.insert(real)
                    out.append(item)
                    queue.append((item.key, real))
                } else {
                    let real = (dir.real == "/" ? "" : dir.real) + "/" + item.name
                    visited.insert(real)
                    out.append(item)
                    queue.append((item.key, real))
                }
            }
        }
        return out
    }

    func download(bucket: String, key: String, size: Int64, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await sftp().download(Self.path(key), to: url, progress: progress)
    }

    func upload(file: URL, size: Int64, bucket: String, key: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let s = try await sftp()
        try await ensureParents(of: key, session: s)
        try await s.upload(file, size: size, to: Self.path(key), progress: progress)
    }

    /// Creates the missing intermediate folders (folder uploads).
    private func ensureParents(of key: String, session s: SFTPSession) async throws {
        let parts = key.split(separator: "/").dropLast()
        var path = ""
        for p in parts {
            path += "/" + p
            if (try? await s.stat(path)) == nil { try? await s.mkdir(path) }
        }
    }

    func createFolder(bucket: String, key: String) async throws {
        let s = try await sftp()
        try await ensureParents(of: key, session: s)
        try await s.mkdir(Self.path(key))
    }

    func delete(bucket: String, items: [RemoteItem]) async throws {
        let s = try await sftp()
        for item in items { try await deleteTree(Self.path(item.key), session: s) }
    }

    /// Deletes a path. Symbolic links are removed as links: their target is never touched.
    private func deleteTree(_ path: String, session s: SFTPSession) async throws {
        guard let attrs = try await s.lstat(path) else { return }
        guard attrs.isDirectory else { try await s.remove(path); return } // file or link (also to a folder)
        let key = Self.key(fromPath: path, isFolder: true)
        let all = try await walk(key, followLinks: false)
        for f in all where !f.isFolder || f.isSymlink { try await s.remove(Self.path(f.key)) }
        // Real folders, deepest first.
        for d in all.filter({ $0.isFolder && !$0.isSymlink }).sorted(by: { $0.key.count > $1.key.count }) {
            try await s.rmdir(Self.path(d.key))
        }
        try await s.rmdir(path)
    }

    func move(bucket: String, item: RemoteItem, toBucket: String, toKey: String, replace: Bool,
              progress: @escaping @Sendable (Int64) -> Void) async throws {
        try MoveCheck.validate(item: item, fromBucket: bucket, toBucket: toBucket, toKey: toKey)
        let s = try await sftp()
        let from = Self.path(item.key), to = Self.path(toKey)
        guard let existing = try await s.lstat(to) else {
            try await s.rename(from, to)
            return
        }
        guard replace else {
            throw SFTPError(code: 11, message: String(localized: "\"\((to as NSString).lastPathComponent)\" already exists at the destination"))
        }
        // File over file: atomic replacement when the server supports it.
        if s.supportsPosixRename, !existing.isDirectory, !(item.isFolder && !item.isSymlink) {
            try await s.posixRename(from, to)
            return
        }
        try await deleteTree(to, session: s)
        try await s.rename(from, to)
    }

    /// Tests only: creates a symbolic link.
    func makeSymlink(target: String, linkKey: String) async throws {
        try await sftp().symlink(target: target, link: Self.path(linkKey))
    }

    func close() { lock.withLock { session?.close(); session = nil } }
}

/// Common checks before moving/renaming.
enum MoveCheck {
    static func validate(item: RemoteItem, fromBucket: String, toBucket: String, toKey: String) throws {
        guard fromBucket == toBucket else { return }
        let src = item.isFolder ? item.key : item.key + "/"
        let dst = toKey.hasSuffix("/") ? toKey : toKey + "/"
        if item.isFolder && !item.isSymlink && dst.hasPrefix(src) && dst != src {
            throw S3Error(status: 0, code: "", message: String(localized: "You can't move \"\(item.name)\" into itself"))
        }
        // Replacing a folder that contains the source would delete the source itself.
        if src.hasPrefix(dst) && src != dst {
            throw S3Error(status: 0, code: "", message: String(localized: "The destination contains \"\(item.name)\": choose another folder"))
        }
    }
}

/// Folder for temporary files (previews and drags to the Finder), removed on quit.
enum TempFiles {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudFerryLite", isDirectory: true)

    /// New unique folder that will hold a file with its original name.
    static func newDirectory() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
