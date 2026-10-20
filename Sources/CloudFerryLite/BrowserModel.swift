import Foundation
import Observation

/// Stato del browser remoto: posizione, cronologia, contenuto della cartella corrente, appunti "Taglia".
@Observable
@MainActor
final class BrowserModel {
    private(set) var location: BrowseLocation?
    private(set) var items: [RemoteItem] = []
    var isLoading = false
    var error: String?

    /// Elementi tagliati (⌘X) in attesa di "Incolla" in un'altra cartella della stessa connessione.
    var cut: (location: BrowseLocation, items: [RemoteItem])?

    private var back: [BrowseLocation] = []
    private var forward: [BrowseLocation] = []
    private var loadTask: Task<Void, Never>?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func open(_ loc: BrowseLocation, store: AppStore, recordHistory: Bool = true) {
        if recordHistory, let current = location, current != loc {
            back.append(current)
            forward.removeAll()
        }
        location = loc
        reload(store: store)
    }

    func goBack(store: AppStore) {
        guard let prev = back.popLast() else { return }
        if let current = location { forward.append(current) }
        open(prev, store: store, recordHistory: false)
    }

    func goForward(store: AppStore) {
        guard let next = forward.popLast() else { return }
        if let current = location { back.append(current) }
        open(next, store: store, recordHistory: false)
    }

    func goUp(store: AppStore) {
        guard let parent = location?.parent else { return }
        open(parent, store: store)
    }

    func reset() {
        loadTask?.cancel()
        location = nil
        items = []
        back.removeAll()
        forward.removeAll()
        cut = nil
    }

    func reload(store: AppStore) {
        guard let loc = location else { return }
        loadTask?.cancel()
        items = []
        error = nil
        isLoading = true
        loadTask = Task {
            defer { if self.location == loc { self.isLoading = false } }
            do {
                let backend = try await store.backend(for: loc.connectionID)
                var token: String?
                var collected: [RemoteItem] = []
                repeat {
                    let page = try await backend.listPage(bucket: loc.bucket, prefix: loc.prefix, token: token)
                    try Task.checkCancellation()
                    collected += page.items
                    // Mostra progressivamente le pagine per i bucket grandi.
                    self.items = Self.dedup(collected)
                    token = page.nextToken
                } while token != nil
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                if self.location == loc { self.error = error.localizedDescription }
            }
        }
    }

    /// Una cartella S3 può comparire sia come CommonPrefix sia come oggetto marker "nome/".
    private static func dedup(_ items: [RemoteItem]) -> [RemoteItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.key).inserted }
    }
}
