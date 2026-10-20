import AppKit
import UniformTypeIdentifiers

/// Dragging from the file table to the Finder with `NSFilePromiseProvider`.
///
/// The Finder only accepts file URLs or AppKit file promises: SwiftUI providers (`itemProvider`/`draggable`)
/// publish generic data that the Finder ignores. Here a monitor intercepts mouseDown on a row of the
/// file table; if a drag follows it starts an NSDraggingSession with one promise per item, otherwise
/// it hands the event back to the table (click, double click and selection are unchanged).
@MainActor
final class FilePromiseDrag: NSObject, NSDraggingSource {
    static let shared = FilePromiseDrag()

    struct Handler {
        /// Items to drag starting from the given row (selects the row if it was not selected).
        var itemsForDrag: (_ row: Int) -> [RemoteItem]
        /// Downloads the item to a temporary location and returns its URL.
        var fetch: (_ item: RemoteItem) async throws -> URL
    }

    var handler: Handler?
    private var monitor: Any?
    nonisolated private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Promise data, read by the callbacks on the delegate queue.
    private final class Promise: @unchecked Sendable {
        let item: RemoteItem
        let fetch: (RemoteItem) async throws -> URL
        init(item: RemoteItem, fetch: @escaping (RemoteItem) async throws -> URL) { self.item = item; self.fetch = fetch }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let handler, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
              let window = event.window, let content = window.contentView, let frame = content.superview,
              let hit = content.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return event }
        var view: NSView? = hit
        while let v = view, !(v is NSTableView) { view = v.superview }
        // The file table has 4 columns; the sidebar only one.
        guard let table = view as? NSTableView, table.tableColumns.count >= 4 else { return event }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return event }

        // Click or drag? Look ahead without consuming the mouseUp.
        let start = event.locationInWindow
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                              inMode: .eventTracking, dequeue: false) else { return event }
            if next.type == .leftMouseUp { return event }
            _ = window.nextEvent(matching: .leftMouseDragged, until: .distantFuture, inMode: .eventTracking, dequeue: true)
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                beginDrag(table: table, row: row, event: event, handler: handler)
                return nil
            }
        }
    }

    private func beginDrag(table: NSTableView, row: Int, event: NSEvent, handler: Handler) {
        let items = handler.itemsForDrag(row)
        guard !items.isEmpty else { return }
        let point = table.convert(event.locationInWindow, from: nil)
        let dragItems: [NSDraggingItem] = items.enumerated().map { i, item in
            let type: UTType = item.isFolder ? .folder : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = Promise(item: item, fetch: handler.fetch)
            let dragItem = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(for: type)
            let offset = CGFloat(i) * 6
            dragItem.setDraggingFrame(NSRect(x: point.x - 16 + offset, y: point.y - 16 - offset, width: 32, height: 32), contents: icon)
            return dragItem
        }
        let session = table.beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // MARK: NSDraggingSource

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Only towards other apps (Finder): "downloading" inside the app makes no sense.
        context == .outsideApplication ? .copy : []
    }
}

extension FilePromiseDrag: NSFilePromiseProviderDelegate {
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? Promise)?.item.name ?? "file"
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        guard let promise = filePromiseProvider.userInfo as? Promise else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        Task { @MainActor in
            do {
                let tmp = try await promise.fetch(promise.item)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.moveItem(at: tmp, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}
