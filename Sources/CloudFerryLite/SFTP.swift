import Foundation

struct SFTPError: LocalizedError {
    var code: UInt32
    var message: String
    var errorDescription: String? {
        switch code {
        case 2: return String(localized: "No such file or folder") + (message.isEmpty ? "" : ": \(message)")
        case 3: return String(localized: "Permission denied") + (message.isEmpty ? "" : ": \(message)")
        default: return message.isEmpty ? String(localized: "SFTP error \(code)") : message
        }
    }
}

struct SFTPAttributes {
    var size: Int64?
    var permissions: UInt32?
    var mtime: Date?

    var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }
    var isSymlink: Bool { (permissions ?? 0) & 0o170000 == 0o120000 }
}

/// SFTP version 3 client using `/usr/bin/ssh -s sftp` as transport: ~/.ssh/config, ssh-agent,
/// known_hosts and ProxyJump all apply. Password, passphrase and host key confirmation go through SSH_ASKPASS.
final class SFTPSession: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [UInt32: CheckedContinuation<(UInt8, Data), Error>] = [:]
    private var nextID: UInt32 = 1
    private var failure: Error?
    private var stderrText = ""
    /// Extensions announced by the server in the VERSION packet (e.g. posix-rename@openssh.com).
    private(set) var extensions: Set<String> = []

    var isAlive: Bool { lock.withLock { failure == nil } && process.isRunning }

    // Packet types (draft-ietf-secsh-filexfer-02).
    private enum T {
        static let initPacket: UInt8 = 1, version: UInt8 = 2, open: UInt8 = 3, close: UInt8 = 4, read: UInt8 = 5
        static let write: UInt8 = 6, lstat: UInt8 = 7, opendir: UInt8 = 11, readdir: UInt8 = 12, remove: UInt8 = 13
        static let mkdir: UInt8 = 14, rmdir: UInt8 = 15, realpath: UInt8 = 16, stat: UInt8 = 17, rename: UInt8 = 18
        static let symlink: UInt8 = 20, extended: UInt8 = 200
        static let status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103, name: UInt8 = 104, attrs: UInt8 = 105
    }

    static let chunkSize = 64 * 1024
    static let window = 16

    private init(arguments: [String], environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.environment = environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        input = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { self?.receive(data) }
        }
        let stderrClosed = DispatchSemaphore(value: 0)
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; stderrClosed.signal(); return }
            guard let self else { return }
            self.lock.withLock { self.stderrText += String(decoding: data, as: UTF8.self) }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            // Wait for the end of stderr (e.g. "Permission denied") before reporting the error.
            _ = stderrClosed.wait(timeout: .now() + 2)
            // ssh ends lines with \r\n (a single Character in Swift): split on Unicode newlines.
            let err = self.lock.withLock { self.stderrText }
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") && !$0.hasPrefix("**") }
                .joined(separator: "\n")
            self.fail(SFTPError(code: 0, message: err.isEmpty ? String(localized: "SSH connection closed (exit code \(p.terminationStatus))") : err))
        }
        try process.run()
    }

    /// Starts ssh and completes the SFTP handshake.
    static func connect(_ conn: Connection, extraOptions: [String] = []) async throws -> SFTPSession {
        var args = ["-T", "-x",
                    "-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=20",
                    "-o", "NumberOfPasswordPrompts=1", "-o", "StrictHostKeyChecking=ask"]
        if let port = conn.port { args += ["-p", String(port)] }
        if !conn.username.isEmpty { args += ["-l", conn.username] }
        switch conn.sftpAuth {
        case .password:
            args += ["-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PubkeyAuthentication=no"]
        case .key:
            let path = (conn.identityFile as NSString).expandingTildeInPath
            if !path.isEmpty { args += ["-i", path, "-o", "IdentitiesOnly=yes"] }
        }
        args += extraOptions
        args += ["-s", conn.host, "sftp"]

        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env[AskPass.modeKey] = "1"
        env[AskPass.connectionKey] = conn.id.uuidString
        env[AskPass.authKey] = conn.sftpAuth.rawValue
        env[AskPass.titleKey] = conn.name
        env[AskPass.languageKey] = Bundle.main.preferredLocalizations.first

        let s = try SFTPSession(arguments: args, environment: env)
        var w = Writer()
        w.u32(3)
        let (type, payload) = try await s.send(T.initPacket, w.data, expectsID: false)
        guard type == T.version else { throw SFTPError(code: 0, message: String(localized: "Invalid SFTP handshake")) }
        var r = Reader(payload)
        let version = try r.u32()
        guard version >= 3 else { throw SFTPError(code: 0, message: String(localized: "SFTP version \(version) is not supported")) }
        var exts: Set<String> = []
        while let name = try? r.string(), (try? r.bytes()) != nil { exts.insert(name) }
        s.extensions = exts
        return s
    }

    func close() {
        if process.isRunning { process.terminate() }
    }

    deinit { close() }

    // MARK: Transport

    private func fail(_ error: Error) {
        let waiting: [CheckedContinuation<(UInt8, Data), Error>] = lock.withLock {
            if failure == nil { failure = error }
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        for c in waiting { c.resume(throwing: error) }
    }

    private func receive(_ data: Data) {
        var ready: [(CheckedContinuation<(UInt8, Data), Error>, UInt8, Data)] = []
        lock.withLock {
            buffer.append(data)
            while buffer.count >= 5 {
                let len = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard buffer.count >= 4 + len else { break }
                let packet = Data(buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + len))
                buffer = Data(buffer.dropFirst(4 + len))
                let type = packet[packet.startIndex]
                var id: UInt32 = 0
                var body = Data(packet.dropFirst())
                if type != T.version, body.count >= 4 {
                    id = body.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    body = Data(body.dropFirst(4))
                }
                if let c = pending.removeValue(forKey: id) { ready.append((c, type, body)) }
            }
        }
        for (c, t, b) in ready { c.resume(returning: (t, b)) }
    }

    private func send(_ type: UInt8, _ body: Data, expectsID: Bool = true) async throws -> (UInt8, Data) {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let failure { lock.unlock(); cont.resume(throwing: failure); return }
            var packet = Writer()
            var id: UInt32 = 0
            if expectsID {
                id = nextID
                nextID &+= 1
            }
            pending[id] = cont
            packet.u32(UInt32(1 + (expectsID ? 4 : 0) + body.count))
            packet.u8(type)
            if expectsID { packet.u32(id) }
            packet.raw(body)
            do {
                try input.write(contentsOf: packet.data)
                lock.unlock()
            } catch {
                pending[id] = nil
                lock.unlock()
                cont.resume(throwing: error)
            }
        }
    }

    /// Sends a request and checks the status; returns the response type and payload.
    private func request(_ type: UInt8, _ build: (inout Writer) -> Void) async throws -> (UInt8, Data) {
        var w = Writer()
        build(&w)
        let (t, body) = try await send(type, w.data)
        if t == T.status {
            var r = Reader(body)
            let code = try r.u32()
            let msg = (try? r.string()) ?? ""
            if code != 0 { throw SFTPError(code: code, message: msg) }
        }
        return (t, body)
    }

    private func expectHandle(_ resp: (UInt8, Data)) throws -> Data {
        guard resp.0 == T.handle else { throw SFTPError(code: 0, message: String(localized: "Unexpected response (\(resp.0))")) }
        var r = Reader(resp.1)
        return try r.bytes()
    }

    // MARK: Operations

    func realpath(_ path: String) async throws -> String {
        let resp = try await request(T.realpath) { $0.string(path) }
        guard resp.0 == T.name else { throw SFTPError(code: 0, message: String(localized: "Invalid realpath response")) }
        var r = Reader(resp.1)
        guard try r.u32() > 0 else { throw SFTPError(code: 2, message: path) }
        return try r.string()
    }

    func stat(_ path: String) async throws -> SFTPAttributes {
        let resp = try await request(T.stat) { $0.string(path) }
        var r = Reader(resp.1)
        return try r.attrs()
    }

    func listDirectory(_ path: String) async throws -> [(name: String, attrs: SFTPAttributes)] {
        let handle = try expectHandle(try await request(T.opendir) { $0.string(path) })
        defer { Task { _ = try? await self.request(T.close) { $0.bytes(handle) } } }
        var out: [(String, SFTPAttributes)] = []
        while true {
            let resp: (UInt8, Data)
            do {
                resp = try await request(T.readdir) { $0.bytes(handle) }
            } catch let e as SFTPError where e.code == 1 { break } // EOF
            guard resp.0 == T.name else { break }
            var r = Reader(resp.1)
            let count = try r.u32()
            for _ in 0..<count {
                let name = try r.string()
                _ = try r.string() // longname
                let a = try r.attrs()
                if name != "." && name != ".." { out.append((name, a)) }
            }
        }
        return out
    }

    func mkdir(_ path: String) async throws { _ = try await request(T.mkdir) { $0.string(path); $0.u32(0) } }
    func rmdir(_ path: String) async throws { _ = try await request(T.rmdir) { $0.string(path) } }
    func remove(_ path: String) async throws { _ = try await request(T.remove) { $0.string(path) } }
    func rename(_ from: String, _ to: String) async throws { _ = try await request(T.rename) { $0.string(from); $0.string(to) } }

    var supportsPosixRename: Bool { extensions.contains("posix-rename@openssh.com") }

    /// Renames, atomically replacing the destination (OpenSSH extension).
    func posixRename(_ from: String, _ to: String) async throws {
        _ = try await request(T.extended) { $0.string("posix-rename@openssh.com"); $0.string(from); $0.string(to) }
    }

    /// Attributes of the path without following symbolic links; nil if it does not exist.
    func lstat(_ path: String) async throws -> SFTPAttributes? {
        do {
            let resp = try await request(T.lstat) { $0.string(path) }
            var r = Reader(resp.1)
            return try r.attrs()
        } catch let e as SFTPError where e.code == 2 {
            return nil
        }
    }

    /// Creates a symbolic link. OpenSSH swaps the order in the spec: target first, then the link.
    func symlink(target: String, link: String) async throws {
        _ = try await request(T.symlink) { $0.string(target); $0.string(link) }
    }

    /// Downloads a file with parallel READ requests (a window of `window` blocks).
    func download(_ path: String, to url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let size = try await stat(path).size ?? 0
        let handle = try expectHandle(try await request(T.open) { $0.string(path); $0.u32(0x01); $0.u32(0) })
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        let fd = out.fileDescriptor
        let counter = ByteCounter()
        do {
            let chunks = stride(from: Int64(0), to: size, by: Self.chunkSize).map { $0 }
            try await TransferManager.forEachConcurrently(chunks, limit: Self.window) { start in
                var offset = start
                let end = min(start + Int64(Self.chunkSize), size)
                // The server may return fewer bytes than requested: read the rest of the block again.
                while offset < end {
                    let len = UInt32(end - offset)
                    let resp: (UInt8, Data)
                    do {
                        resp = try await self.request(T.read) { $0.bytes(handle); $0.u64(UInt64(offset)); $0.u32(len) }
                    } catch let e as SFTPError where e.code == 1 { return } // EOF
                    var r = Reader(resp.1)
                    let data = try r.bytes()
                    if data.isEmpty { return }
                    let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
                    guard written == data.count else { throw SFTPError(code: 0, message: String(localized: "Local write failed")) }
                    offset += Int64(data.count)
                    progress(counter.add(Int64(data.count)))
                }
            }
        } catch {
            _ = try? await request(T.close) { $0.bytes(handle) }
            throw error
        }
        _ = try await request(T.close) { $0.bytes(handle) }
    }

    /// Uploads a file with parallel WRITE requests.
    func upload(_ url: URL, size: Int64, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        // WRITE | CREAT | TRUNC, permissions 0644.
        let handle = try expectHandle(try await request(T.open) { $0.string(path); $0.u32(0x02 | 0x08 | 0x10); $0.u32(0x04); $0.u32(0o644) })
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let fd = input.fileDescriptor
        let counter = ByteCounter()
        do {
            let chunks = stride(from: Int64(0), to: size, by: Self.chunkSize).map { $0 }
            try await TransferManager.forEachConcurrently(chunks, limit: Self.window) { start in
                try Task.checkCancellation()
                let len = Int(min(Int64(Self.chunkSize), size - start))
                var data = Data(count: len)
                let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, len, off_t(start)) }
                guard n == len else { throw SFTPError(code: 0, message: String(localized: "Local read failed")) }
                _ = try await self.request(T.write) { $0.bytes(handle); $0.u64(UInt64(start)); $0.bytes(data) }
                progress(counter.add(Int64(len)))
            }
        } catch {
            _ = try? await request(T.close) { $0.bytes(handle) }
            throw error
        }
        _ = try await request(T.close) { $0.bytes(handle) }
    }

    // MARK: Encoding

    struct Writer {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        mutating func bytes(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
        mutating func string(_ s: String) { bytes(Data(s.utf8)) }
        mutating func raw(_ d: Data) { data.append(d) }
    }

    struct Reader {
        private let data: Data
        private var pos: Int

        init(_ d: Data) { data = d; pos = d.startIndex }

        mutating func take(_ n: Int) throws -> Data {
            guard pos + n <= data.endIndex else { throw SFTPError(code: 0, message: String(localized: "Truncated SFTP packet")) }
            defer { pos += n }
            return data.subdata(in: pos ..< pos + n)
        }
        mutating func u32() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func u64() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
        mutating func bytes() throws -> Data { try take(Int(u32())) }
        mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }

        mutating func attrs() throws -> SFTPAttributes {
            var a = SFTPAttributes()
            let flags = try u32()
            if flags & 0x1 != 0 { a.size = Int64(bitPattern: try u64()) }
            if flags & 0x2 != 0 { _ = try u32(); _ = try u32() }
            if flags & 0x4 != 0 { a.permissions = try u32() }
            if flags & 0x8 != 0 { _ = try u32(); a.mtime = Date(timeIntervalSince1970: TimeInterval(try u32())) }
            if flags & 0x8000_0000 != 0 {
                let n = try u32()
                for _ in 0..<n { _ = try bytes(); _ = try bytes() }
            }
            return a
        }
    }
}

/// Byte counter shared by parallel tasks.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func add(_ n: Int64) -> Int64 { lock.withLock { value += n; return value } }
}
