import AppKit
import UniformTypeIdentifiers

/// Trascinamento dalla tabella file verso il Finder con `NSFilePromiseProvider`.
///
/// Il Finder accetta solo URL di file o "file promise" AppKit: i provider SwiftUI (`itemProvider`/`draggable`)
/// pubblicano dati generici che il Finder ignora. Qui un monitor intercetta il mouseDown su una riga della
/// tabella file; se segue un trascinamento avvia una NSDraggingSession con un promise per elemento, altrimenti
/// restituisce l'evento alla tabella (clic, doppio clic e selezione restano invariati).
@MainActor
final class FilePromiseDrag: NSObject, NSDraggingSource {
    static let shared = FilePromiseDrag()

    struct Handler {
        /// Elementi da trascinare partendo dalla riga indicata (seleziona la riga se non lo era).
        var itemsForDrag: (_ row: Int) -> [RemoteItem]
        /// Scarica l'elemento in una posizione temporanea e ne restituisce l'URL.
        var fetch: (_ item: RemoteItem) async throws -> URL
    }

    var handler: Handler?
    private var monitor: Any?
    nonisolated private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Dati del promise, letti dai callback sul queue del delegate.
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
        // La tabella file ha 4 colonne; la sidebar una sola.
        guard let table = view as? NSTableView, table.tableColumns.count >= 4 else { return event }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return event }

        // Clic o trascinamento? Si guarda avanti senza consumare il mouseUp.
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
        // Solo verso altre app (Finder): dentro l'app non ha senso "scaricare".
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
