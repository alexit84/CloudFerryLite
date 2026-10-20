import Foundation
import Observation
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted after uploads, moves and deletions; userInfo: "bucket", "connection".
    static let remoteContentChanged = Notification.Name("RemoteContentChanged")
}

@Observable
@MainActor
final class TransferItem: Identifiable {
    enum Kind { case upload, download, move, delete }
    enum State: Equatable {
        case queued, running, done, cancelled
        case failed(String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    var state: State = .queued
    var totalBytes: Int64 = 0
    var filesTotal = 0
    var filesDone = 0
    fileprivate var bytesPerFile: [String: Int64] = [:]
    fileprivate var finishedBytes: Int64 = 0
    fileprivate var finishedFiles: Set<String> = []
    fileprivate var task: Task<Void, Never>?
    fileprivate let work: (TransferItem) async throws -> Void
    fileprivate var waiters: [CheckedContinuation<Void, Error>] = []

    var doneBytes: Int64 { finishedBytes + bytesPerFile.values.reduce(0, +) }
    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : (state == .done ? 1 : 0) }
    var isActive: Bool { state == .queued || state == .running }

    init(kind: Kind, title: String, detail: String, work: @escaping (TransferItem) async throws -> Void) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.work = work
    }

    func progress(_ file: String, _ bytes: Int64) {
        // A late update must not reopen a file that is already complete.
        guard !finishedFiles.contains(file) else { return }
        bytesPerFile[file] = bytes
    }

    func fileFinished(_ file: String, size: Int64) {
        finishedFiles.insert(file)
        bytesPerFile[file] = nil
        finishedBytes += size
        filesDone += 1
    }

    fileprivate func finish(_ state: State) {
        self.state = state
        let result: Result<Void, Error>
        switch state {
        case .done: result = .success(())
        case .failed(let m): result = .failure(S3Error(status: 0, code: "", message: m))
        default: result = .failure(CancellationError())
        }
        for w in waiters { w.resume(with: result) }
        waiters.removeAll()
    }
}

/// Operation queue: at most `maxConcurrent` active items, each with internal parallelism over its files.
@Observable
@MainActor
final class TransferManager {
    var items: [TransferItem] = []
    let maxConcurrent = 3
    nonisolated static let filesInParallel = 4

    var activeCount: Int { items.filter(\.isActive).count }

    func clearFinished() { items.removeAll { !$0.isActive } }

    func cancel(_ item: TransferItem) {
        item.task?.cancel()
        if item.state == .queued { item.finish(.cancelled) }
    }

    @discardableResult
    private func enqueue(_ item: TransferItem) -> TransferItem {
        items.insert(item, at: 0)
        pump()
        return item
    }

    /// Waits for the operation to finish (used by drag to the Finder and by the preview).
    func wait(_ item: TransferItem) async throws {
        switch item.state {
        case .done: return
        case .failed(let m): throw S3Error(status: 0, code: "", message: m)
        case .cancelled: throw CancellationError()
        default: try await withCheckedThrowingContinuation { item.waiters.append($0) }
        }
    }

    private func pump() {
        let running = items.filter { $0.state == .running }.count
        guard running < maxConcurrent,
              let next = items.last(where: { $0.state == .queued }) else { return }
        next.state = .running
        next.task = Task {
            do {
                try await next.work(next)
                next.finish(.done)
            } catch is CancellationError {
                next.finish(.cancelled)
            } catch let e as URLError where e.code == .cancelled {
                next.finish(.cancelled)
            } catch {
                next.finish(.failed(error.localizedDescription))
            }
            pump()
        }
        pump()
    }

    private static func changed(_ loc: BrowseLocation, bucket: String? = nil) {
        NotificationCenter.default.post(name: .remoteContentChanged, object: nil,
                                        userInfo: ["bucket": bucket ?? loc.bucket, "connection": loc.connectionID])
    }

    // MARK: Download

    /// Downloads files and folders (recursively) into the local folder `destination`.
    @discardableResult
    func download(_ selection: [RemoteItem], from loc: BrowseLocation, backend: any RemoteBackend, to destination: URL,
                  title: String? = nil) -> TransferItem {
        let label = title ?? (selection.count == 1 ? selection[0].name + (selection[0].isFolder ? "/" : "") : String(localized: "\(selection.count) items"))
        return enqueue(TransferItem(kind: .download, title: label, detail: "→ \(destination.path)") { t in
            // Files to download, with their path relative to the current folder.
            var files: [(key: String, rel: String, size: Int64)] = []
            for item in selection {
                if item.isFolder {
                    let base = destination.appendingPathComponent(item.name)
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                    for o in try await backend.listAll(bucket: loc.bucket, prefix: item.key) {
                        let rel = item.name + "/" + o.key.dropFirst(item.key.count)
                        if o.isFolder {
                            try FileManager.default.createDirectory(at: destination.appendingPathComponent(rel),
                                                                    withIntermediateDirectories: true)
                        } else {
                            files.append((o.key, rel, o.size))
                        }
                    }
                } else {
                    files.append((item.key, item.name, item.size))
                }
            }
            t.filesTotal = files.count
            t.totalBytes = files.reduce(0) { $0 + $1.size }

            try await Self.forEachConcurrently(files, limit: Self.filesInParallel) { f in
                let target = destination.appendingPathComponent(f.rel)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await backend.download(bucket: loc.bucket, key: f.key, size: f.size, to: target) { done in
                    Task { @MainActor in t.progress(f.key, done) }
                }
                await MainActor.run { t.fileFinished(f.key, size: f.size) }
            }
        })
    }

    // MARK: Upload

    /// Uploads local files and folders under the current location.
    func upload(_ urls: [URL], to loc: BrowseLocation, backend: any RemoteBackend) {
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = url.lastPathComponent
            enqueue(TransferItem(kind: .upload, title: isDir ? name + "/" : name, detail: "→ \(loc.bucket)/\(loc.prefix)") { t in
                var files: [(url: URL, key: String, size: Int64)] = []
                if isDir {
                    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                    let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
                    let base = url.standardizedFileURL.path
                    while let f = en?.nextObject() as? URL {
                        let rv = try? f.resourceValues(forKeys: Set(keys))
                        guard rv?.isRegularFile == true, f.lastPathComponent != ".DS_Store" else { continue }
                        let rel = String(f.standardizedFileURL.path.dropFirst(base.count + 1))
                        files.append((f, loc.prefix + name + "/" + rel, Int64(rv?.fileSize ?? 0)))
                    }
                    if files.isEmpty { try await backend.createFolder(bucket: loc.bucket, key: loc.prefix + name + "/") }
                } else {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    files = [(url, loc.prefix + name, Int64(size))]
                }
                t.filesTotal = files.count
                t.totalBytes = files.reduce(0) { $0 + $1.size }

                try await Self.forEachConcurrently(files, limit: Self.filesInParallel) { f in
                    try await backend.upload(file: f.url, size: f.size, bucket: loc.bucket, key: f.key) { done in
                        Task { @MainActor in t.progress(f.key, done) }
                    }
                    await MainActor.run { t.fileFinished(f.key, size: f.size) }
                }
                Self.changed(loc)
            })
        }
    }

    // MARK: Moves and deletions

    /// Moves (or renames) every item to `toKey(item)` inside `toBucket`.
    @discardableResult
    func move(_ selection: [(item: RemoteItem, toKey: String)], from loc: BrowseLocation, toBucket: String,
              backend: any RemoteBackend, title: String, replace: Bool = false, onMoved: @escaping @MainActor (RemoteItem, String) -> Void = { _, _ in }) -> TransferItem {
        enqueue(TransferItem(kind: .move, title: title, detail: "\(loc.bucket)/\(loc.prefix)") { t in
            t.filesTotal = selection.count
            t.totalBytes = selection.reduce(0) { $0 + ($1.item.isFolder ? 0 : $1.item.size) }
            defer { Self.changed(loc); if toBucket != loc.bucket { Self.changed(loc, bucket: toBucket) } }
            for (item, toKey) in selection {
                try Task.checkCancellation()
                try await backend.move(bucket: loc.bucket, item: item, toBucket: toBucket, toKey: toKey, replace: replace) { done in
                    Task { @MainActor in t.progress(item.key, done) }
                }
                await MainActor.run {
                    t.fileFinished(item.key, size: item.isFolder ? 0 : item.size)
                    onMoved(item, toKey)
                }
            }
        })
    }

    @discardableResult
    func delete(_ selection: [RemoteItem], from loc: BrowseLocation, backend: any RemoteBackend) -> TransferItem {
        let title = selection.count == 1 ? selection[0].name : String(localized: "\(selection.count) items")
        return enqueue(TransferItem(kind: .delete, title: title, detail: "\(loc.bucket)/\(loc.prefix)") { t in
            t.filesTotal = selection.count
            defer { Self.changed(loc) }
            try await backend.delete(bucket: loc.bucket, items: selection)
            t.filesDone = selection.count
        })
    }

    /// Runs `body` on every item with at most `limit` operations in parallel.
    nonisolated static func forEachConcurrently<T: Sendable>(_ items: [T], limit: Int,
                                                             _ body: @escaping @Sendable (T) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = items.makeIterator()
            for _ in 0..<limit {
                guard let next = it.next() else { break }
                group.addTask { try await body(next) }
            }
            while try await group.next() != nil {
                if let next = it.next() { group.addTask { try await body(next) } }
            }
        }
    }
}

/// Reports the bytes transferred by observing the task created by URLSession.
final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: (Int64) -> Void
    private var observation: NSKeyValueObservation?
    private var lastReported: Int64 = -1

    init(_ onProgress: @escaping (Int64) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.observe(\.countOfBytesReceived) { [weak self] t, _ in
            self?.report(t.countOfBytesReceived)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }

    private func report(_ bytes: Int64) {
        // Throttle UI updates (roughly every 256 KB).
        guard bytes - lastReported >= 256 * 1024 || lastReported < 0 else { return }
        lastReported = bytes
        onProgress(bytes)
    }
}

extension URL {
    var mimeType: String {
        UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
