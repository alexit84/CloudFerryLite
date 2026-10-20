import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Bindable var model: BrowserModel
    @Environment(AppStore.self) private var store
    @Environment(TransferManager.self) private var transfers

    @State private var selection: Set<RemoteItem.ID> = []
    @State private var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)]
    @State private var search = ""
    @State private var dropTargeted = false
    @State private var newFolderPrompt = false
    @State private var newFolderName = ""
    @State private var renaming: RemoteItem?
    @State private var renameText = ""
    @State private var pendingDelete: [RemoteItem] = []
    @State private var sharing: RemoteItem?
    /// Move waiting for confirmation because the destination already contains items with the same name.
    @State private var pendingReplace: PendingMove?

    private struct PendingMove {
        var cut: (location: BrowseLocation, items: [RemoteItem])
        var dest: BrowseLocation
        var moves: [(item: RemoteItem, toKey: String)]
        var conflicts: [String]
    }
    @State private var actionError: String?
    @State private var showTransfers = false
    @State private var previewURL: URL?
    @State private var previewTask: TransferItem?
    @State private var previewCache: [String: URL] = [:]
    @AppStorage("lastDownloadFolder") private var lastDownloadFolder = ""

    private static let cutMarker = "cloudferrylite-cut:"

    var body: some View {
        Group {
            if let loc = model.location {
                VStack(spacing: 0) {
                    breadcrumb(loc)
                    Divider()
                    table
                        .overlay { overlay }
                    if !transfers.items.isEmpty {
                        Divider()
                        TransfersView(expanded: $showTransfers)
                    }
                }
                .navigationTitle(loc.title)
                .navigationSubtitle(connection?.name ?? "")
                .toolbar { toolbar(loc) }
                .searchable(text: $search, placement: .toolbar, prompt: "Filter this folder")
            } else {
                ContentUnavailableView("No folder selected", systemImage: "shippingbox",
                                       description: Text("Pick a bucket, a folder or a favorite in the sidebar."))
            }
        }
        .quickLookPreview($previewURL)
        .onAppear { registerDragOut() }
        .onChange(of: model.location) { _, _ in selection = []; search = "" }
        .onReceive(NotificationCenter.default.publisher(for: .remoteContentChanged)) { note in
            guard let loc = model.location,
                  note.userInfo?["bucket"] as? String == loc.bucket,
                  note.userInfo?["connection"] as? UUID == loc.connectionID else { return }
            model.reload(store: store)
        }
        .onChange(of: transfers.items.count) { old, new in if new > old { showTransfers = true } }
        .alert("New folder", isPresented: $newFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $renameText)
            Button("Rename") { if let r = renaming { rename(r, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if renaming?.isFolder == true, connection?.kind == .s3 {
                Text("On S3, renaming a folder copies and then deletes every object it contains.")
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty },
                                                              set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) { performDelete(pendingDelete) }
        } message: {
            Text("Folders are deleted with all their contents. This cannot be undone.")
        }
        .sheet(item: $sharing) { item in
            if let loc = model.location { ShareLinkSheet(item: item, location: loc) }
        }
        .confirmationDialog(replaceTitle, isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } })) {
            Button("Replace", role: .destructive) {
                if let p = pendingReplace { performMove(p.moves, cut: p.cut, dest: p.dest, replace: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing items with the same name will be deleted (folders with all their contents).")
        }
        .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var connection: Connection? { model.location.flatMap { store.connection($0.connectionID) } }

    // MARK: Contents

    private var visibleItems: [RemoteItem] {
        var list = model.items
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        list.sort(using: sortOrder)
        // Folders always on top.
        return list.filter(\.isFolder) + list.filter { !$0.isFolder }
    }

    private var table: some View {
        Table(of: RemoteItem.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                Label {
                    Text(item.name)
                        .foregroundStyle(isCut(item) ? .secondary : .primary)
                } icon: {
                    Image(systemName: item.isSymlink ? (item.isFolder ? "folder" : "link")
                                                     : (item.isFolder ? "folder.fill" : icon(for: item.name)))
                        .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
                }
                .opacity(isCut(item) ? 0.55 : 1)
            }
            .width(min: 200, ideal: 380)
            TableColumn("Size", value: \.sizeSort) { item in
                Text(item.isFolder ? "—" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modifiedSort) { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Kind", value: \.kindSort) { item in
                Text(kindLabel(item))
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
        } rows: {
            ForEach(visibleItems) { item in
                TableRow(item)
            }
        }
        .contextMenu(forSelectionType: RemoteItem.ID.self) { ids in
            contextMenu(items(ids))
        } primaryAction: { ids in
            let sel = items(ids)
            if sel.count == 1, sel[0].isFolder {
                open(sel[0])
            } else if !sel.isEmpty {
                download(sel)
            }
        }
        .onKeyPress(.space) {
            guard let item = selectedItems.first(where: { !$0.isFolder }) else { return .ignored }
            preview(item)
            return .handled
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { upload(await fileURLs(from: providers)) }
            return true
        }
        .onDeleteCommand { if !selectedItems.isEmpty { pendingDelete = selectedItems } }
        .onCutCommand {
            guard let loc = model.location, !selectedItems.isEmpty else { return [] }
            model.cut = (loc, selectedItems)
            return [NSItemProvider(object: (Self.cutMarker + loc.connectionID.uuidString) as NSString)]
        }
        .onPasteCommand(of: [.fileURL, .plainText]) { providers in
            Task { await paste(providers) }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if let err = model.error {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            } actions: {
                Button("Retry") { model.reload(store: store) }
            }
            .background(.background)
        } else if model.isLoading && model.items.isEmpty {
            ProgressView("Loading…")
        } else if !model.isLoading && model.items.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder",
                                   description: Text("Drag files or folders here from the Finder to upload them."))
        }
        if let p = previewTask, p.isActive {
            VStack(spacing: 8) {
                ProgressView(value: p.fraction) { Text("Preparing preview of \(p.title)…") }
                    .frame(width: 260)
                Button("Cancel") { transfers.cancel(p) }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        if dropTargeted {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .background(Color.accentColor.opacity(0.08))
                .overlay(Label("Drop to upload here", systemImage: "arrow.up.doc").font(.title3))
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    private func breadcrumb(_ loc: BrowseLocation) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let isSFTP = connection?.kind == .sftp
                crumb(isSFTP ? "/" : loc.bucket, systemImage: isSFTP ? "internaldrive" : "shippingbox",
                      target: BrowseLocation(connectionID: loc.connectionID, bucket: loc.bucket, prefix: ""))
                ForEach(Array(loc.segments.enumerated()), id: \.offset) { i, seg in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    let prefix = loc.segments[0...i].joined(separator: "/") + "/"
                    crumb(seg, systemImage: "folder", target: BrowseLocation(connectionID: loc.connectionID, bucket: loc.bucket, prefix: prefix))
                }
                Spacer(minLength: 12)
                if let cut = model.cut {
                    Label("\(cut.items.count) to move", systemImage: "scissors")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Paste here") { pasteCut() }.controlSize(.small)
                    Button { model.cut = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel move")
                    Divider().frame(height: 14)
                }
                if model.isLoading && !model.items.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("\(model.items.count) items…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func crumb(_ title: String, systemImage: String, target: BrowseLocation) -> some View {
        Button {
            model.open(target, store: store)
        } label: {
            Label(title, systemImage: systemImage).font(.callout)
        }
        .buttonStyle(.borderless)
        .disabled(target == model.location)
    }

    private var summary: String {
        let files = model.items.filter { !$0.isFolder }
        let folders = model.items.count - files.count
        let size = ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
        if !selection.isEmpty { return String(localized: "\(selection.count) selected") }
        let folderText = folders == 1 ? String(localized: "1 folder") : String(localized: "\(folders) folders")
        let fileText = files.count == 1 ? String(localized: "1 file") : String(localized: "\(files.count) files")
        return "\(folderText), \(fileText) · \(size)"
    }

    // MARK: Toolbar & menu

    @ToolbarContentBuilder
    private func toolbar(_ loc: BrowseLocation) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack(store: store) } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
            Button { model.goForward(store: store) } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
            Button { model.goUp(store: store) } label: { Label("Enclosing folder", systemImage: "arrow.up") }
                .disabled(loc.parent == nil)
                .keyboardShortcut(.upArrow, modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.reload(store: store) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
            Button {
                store.toggleFavorite(loc)
            } label: {
                Label("Favorite", systemImage: store.favorite(for: loc) == nil ? "star" : "star.fill")
            }
            .help(store.favorite(for: loc) == nil ? "Add to Favorites" : "Remove from Favorites")
            .keyboardShortcut("d", modifiers: .command)
            Button { newFolderName = ""; newFolderPrompt = true } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Menu {
                Button("Upload files…") { pickUpload(directories: false) }
                Button("Upload folder…") { pickUpload(directories: true) }
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            } primaryAction: {
                pickUpload(directories: false)
            }
            Button { download(selectedItems) } label: { Label("Download", systemImage: "square.and.arrow.down") }
                .disabled(selection.isEmpty)
            Button(role: .destructive) { pendingDelete = selectedItems } label: { Label("Delete", systemImage: "trash") }
                .disabled(selection.isEmpty)
            Button { showTransfers.toggle() } label: {
                Label("Activity", systemImage: transfers.activeCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
            }
            .disabled(transfers.items.isEmpty)
        }
    }

    @ViewBuilder
    private func contextMenu(_ sel: [RemoteItem]) -> some View {
        if let loc = model.location {
            if sel.count == 1, sel[0].isFolder {
                Button("Open") { open(sel[0]) }
                let folderLoc = BrowseLocation(connectionID: loc.connectionID, bucket: loc.bucket, prefix: sel[0].key)
                Button(store.favorite(for: folderLoc) == nil ? "Add to Favorites" : "Remove from Favorites") {
                    store.toggleFavorite(folderLoc)
                }
                Divider()
            }
            if sel.count == 1, !sel[0].isFolder {
                Button("Quick Look (Space)") { preview(sel[0]) }
            }
            if !sel.isEmpty {
                Button("Download…") { download(sel) }
                Divider()
                if sel.count == 1 {
                    Button("Rename…") { renameText = sel[0].name; renaming = sel[0] }
                }
                Button("Cut (⌘X)") { model.cut = (loc, sel) }
                if model.cut != nil { Button("Paste here") { pasteCut() } }
                Divider()
                if sel.count == 1 {
                    if connection?.kind == .s3, !sel[0].isFolder {
                        Button("Create shareable link…") { sharing = sel[0] }
                    }
                    Button("Copy path") { copy(path(of: sel[0], in: loc)) }
                    if connection?.kind == .s3 { Button("Copy key") { copy(sel[0].key) } }
                    Divider()
                }
                Button("Delete…", role: .destructive) { pendingDelete = sel }
            } else {
                Button("New folder…") { newFolderName = ""; newFolderPrompt = true }
                Button("Upload files…") { pickUpload(directories: false) }
                Button("Upload folder…") { pickUpload(directories: true) }
                if model.cut != nil { Button("Paste here") { pasteCut() } }
                Button("Refresh") { model.reload(store: store) }
            }
        }
    }

    // MARK: Actions

    private var selectedItems: [RemoteItem] { items(selection) }

    private func items(_ ids: Set<RemoteItem.ID>) -> [RemoteItem] { model.items.filter { ids.contains($0.id) } }

    private func isCut(_ item: RemoteItem) -> Bool {
        guard let cut = model.cut, cut.location.connectionID == model.location?.connectionID,
              cut.location.bucket == model.location?.bucket else { return false }
        return cut.items.contains { $0.key == item.key }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? String(localized: "Delete \"\(pendingDelete[0].name)\"?") : String(localized: "Delete \(pendingDelete.count) items?")
    }

    private func path(of item: RemoteItem, in loc: BrowseLocation) -> String {
        guard let conn = connection else { return item.key }
        switch conn.kind {
        case .s3: return "s3://\(loc.bucket)/\(item.key)"
        case .sftp: return "/" + item.key
        }
    }

    private func open(_ folder: RemoteItem) {
        guard let loc = model.location else { return }
        model.open(BrowseLocation(connectionID: loc.connectionID, bucket: loc.bucket, prefix: folder.key), store: store)
    }

    /// Runs an action that needs the backend, showing any error.
    private func withBackend(_ action: @escaping (any RemoteBackend, BrowseLocation) async throws -> Void) {
        guard let loc = model.location else { return }
        Task {
            do {
                try await action(try await store.backend(for: loc.connectionID), loc)
            } catch is CancellationError {
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func pickUpload(directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        withBackend { backend, loc in transfers.upload(urls, to: loc, backend: backend) }
    }

    private func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let u = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(u)
            }
        }
        return urls
    }

    /// ⌘V: files copied in the Finder → upload; items cut here → move.
    private func paste(_ providers: [NSItemProvider]) async {
        let urls = await fileURLs(from: providers)
        if !urls.isEmpty { upload(urls); return }
        if model.cut != nil { pasteCut() }
    }

    private func download(_ sel: [RemoteItem]) {
        guard !sel.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Download here")
        panel.message = String(localized: "Choose the destination folder")
        panel.directoryURL = lastDownloadFolder.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            : URL(fileURLWithPath: lastDownloadFolder)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        lastDownloadFolder = dest.path
        withBackend { backend, loc in transfers.download(sel, from: loc, backend: backend, to: dest) }
    }

    /// Downloads into a temporary folder (preview and drag to the Finder).
    private func fetchToTemp(_ item: RemoteItem, _ loc: BrowseLocation) async throws -> (URL, TransferItem) {
        let backend = try await store.backend(for: loc.connectionID)
        let dir = try TempFiles.newDirectory()
        let t = transfers.download([item], from: loc, backend: backend, to: dir,
                                   detail: String(localized: "Temporary copy (Quick Look / drag)"))
        return (dir.appendingPathComponent(item.name), t)
    }

    private func preview(_ item: RemoteItem) {
        guard let loc = model.location else { return }
        let cacheKey = "\(loc.connectionID)|\(loc.bucket)|\(item.key)|\(item.size)|\(item.modified?.timeIntervalSince1970 ?? 0)"
        if let cached = previewCache[cacheKey], FileManager.default.fileExists(atPath: cached.path) {
            previewURL = cached
            return
        }
        Task {
            do {
                let (url, t) = try await fetchToTemp(item, loc)
                previewTask = t
                try await transfers.wait(t)
                previewCache[cacheKey] = url
                previewURL = url
            } catch is CancellationError {
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Drag to the Finder (AppKit file promises): the download starts on drop.
    private func registerDragOut() {
        FilePromiseDrag.shared.install()
        FilePromiseDrag.shared.handler = .init(
            itemsForDrag: { row in
                let list = visibleItems
                guard row < list.count else { return [] }
                let item = list[row]
                if selection.contains(item.id) { return list.filter { selection.contains($0.id) } }
                selection = [item.id]
                return [item]
            },
            fetch: { item in
                guard let loc = model.location else { throw CancellationError() }
                let (url, t) = try await fetchToTemp(item, loc)
                try await transfers.wait(t)
                return url
            })
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { return }
        withBackend { backend, loc in
            try await backend.createFolder(bucket: loc.bucket, key: loc.prefix + name + "/")
            model.reload(store: store)
        }
    }

    private func rename(_ item: RemoteItem, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != item.name else { return }
        guard !name.contains("/") else { actionError = String(localized: "The name can't contain \"/\""); return }
        guard !model.items.contains(where: { $0.name == name }) else { actionError = String(localized: "An item named \"\(name)\" already exists"); return }
        let toKey = item.parentPrefix + name + (item.isFolder ? "/" : "")
        withBackend { backend, loc in
            transfers.move([(item, toKey)], from: loc, toBucket: loc.bucket, backend: backend,
                           title: "\(item.name) → \(name)") { moved, key in
                if moved.isFolder {
                    store.favoritesMoved(connectionID: loc.connectionID, bucket: loc.bucket, fromPrefix: moved.key,
                                         toBucket: loc.bucket, toPrefix: key)
                }
            }
        }
    }

    /// Moves the cut items into the current folder.
    private func pasteCut() {
        guard let cut = model.cut, let dest = model.location else { return }
        guard cut.location.connectionID == dest.connectionID else {
            actionError = String(localized: "Items can only be moved within the same connection.")
            return
        }
        var moves: [(item: RemoteItem, toKey: String)] = []
        for item in cut.items {
            let toKey = dest.prefix + item.name + (item.isFolder ? "/" : "")
            if cut.location.bucket == dest.bucket {
                if item.key == toKey { continue } // same folder
                if item.isFolder && dest.prefix.hasPrefix(item.key) {
                    actionError = String(localized: "You can't move \"\(item.name)\" into itself.")
                    return
                }
            }
            moves.append((item, toKey))
        }
        model.cut = nil
        guard !moves.isEmpty else { return }
        // Names already present in the destination folder (the one shown).
        let existing = Set(model.items.map(\.name))
        let conflicts = moves.map(\.item.name).filter(existing.contains)
        if !conflicts.isEmpty {
            pendingReplace = PendingMove(cut: cut, dest: dest, moves: moves, conflicts: conflicts)
            return
        }
        performMove(moves, cut: cut, dest: dest, replace: false)
    }

    private var replaceTitle: String {
        guard let p = pendingReplace else { return "" }
        return p.conflicts.count == 1 ? String(localized: "\"\(p.conflicts[0])\" already exists. Replace it?")
                                      : String(localized: "\(p.conflicts.count) items already exist. Replace them?")
    }

    private func performMove(_ moves: [(item: RemoteItem, toKey: String)], cut: (location: BrowseLocation, items: [RemoteItem]),
                             dest: BrowseLocation, replace: Bool) {
        let title = moves.count == 1 ? String(localized: "Move \(moves[0].item.name)") : String(localized: "Move \(moves.count) items")
        withBackend { backend, _ in
            transfers.move(moves, from: cut.location, toBucket: dest.bucket, backend: backend, title: title, replace: replace) { moved, key in
                if moved.isFolder {
                    store.favoritesMoved(connectionID: dest.connectionID, bucket: cut.location.bucket, fromPrefix: moved.key,
                                         toBucket: dest.bucket, toPrefix: key)
                }
            }
        }
    }

    private func performDelete(_ sel: [RemoteItem]) {
        withBackend { backend, loc in
            transfers.delete(sel, from: loc, backend: backend)
            selection = []
        }
    }

    private func kindLabel(_ item: RemoteItem) -> String {
        if item.isSymlink { return item.isFolder ? String(localized: "Folder link") : String(localized: "Link") }
        return item.isFolder ? String(localized: "Folder") : (item.name as NSString).pathExtension.uppercased()
    }

    private func icon(for name: String) -> String {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// Presigned link to share an S3 object without credentials.
struct ShareLinkSheet: View {
    let item: RemoteItem
    let location: BrowseLocation
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var duration: TimeInterval = 86_400
    @State private var url: URL?
    @State private var limit: Date?
    @State private var error: String?
    @State private var copied = false

    private let durations: [(String, TimeInterval)] = [
        (String(localized: "15 minutes"), 900), (String(localized: "1 hour"), 3600), (String(localized: "12 hours"), 43_200),
        (String(localized: "1 day"), 86_400), (String(localized: "7 days (maximum)"), 604_800),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shareable link").font(.headline)
            Text(item.name).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Picker("Expires after", selection: $duration) {
                ForEach(durations, id: \.1) { Text($0.0).tag($0.1) }
            }
            if let url {
                TextField("", text: .constant(url.absoluteString), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...5).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let limit {
                Label("The SSO credentials expire on \(limit.formatted(date: .abbreviated, time: .shortened)): the link will stop working then.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(copied ? "Copied ✓" : "Copy link") {
                    if let url { copy(url.absoluteString); copied = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: duration) { await generate() }
    }

    private func generate() async {
        copied = false
        do {
            guard let s3 = try await store.backend(for: location.connectionID) as? S3Backend else { return }
            url = s3.client.presignedURL(bucket: location.bucket, key: item.key, expires: duration)
            let exp = s3.client.credentials.expiration
            limit = exp.flatMap { $0 < Date().addingTimeInterval(duration) ? $0 : nil }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TransfersView: View {
    @Environment(TransferManager.self) private var transfers
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Label("Activity", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderless)
                if transfers.activeCount > 0 {
                    Text("\(transfers.activeCount) in progress").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear finished") { transfers.clearFinished() }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if expanded {
                List(transfers.items) { item in
                    TransferRow(item: item)
                }
                .listStyle(.plain)
                .frame(height: 170)
            }
        }
        .background(.bar)
    }
}

struct TransferRow: View {
    let item: TransferItem
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(statusColor).lineLimit(1)
                }
                if item.state == .running {
                    if item.totalBytes > 0 {
                        ProgressView(value: item.fraction).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if item.isActive {
                Button { transfers.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch item.kind {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .move: return "arrow.right.circle"
        case .delete: return "trash.circle"
        }
    }

    private var color: Color {
        switch item.kind {
        case .upload: return .blue
        case .download: return .green
        case .move: return .orange
        case .delete: return .red
        }
    }

    private var status: String {
        let bytes = "\(ByteCountFormatter.string(fromByteCount: item.doneBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))"
        let files = item.filesTotal > 1 ? " · \(item.filesDone)/\(item.filesTotal)" : ""
        switch item.state {
        case .queued: return String(localized: "Queued")
        case .running:
            if item.kind == .delete { return String(localized: "Deleting…") }
            return item.totalBytes > 0 ? bytes + files : (item.filesTotal > 0 ? String(localized: "In progress") + files : String(localized: "Preparing…"))
        case .done:
            switch item.kind {
            case .delete: return String(localized: "Deleted")
            case .move: return String(localized: "Moved") + files
            default: return String(localized: "Completed") + " · " + ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) + files
            }
        case .cancelled: return String(localized: "Cancelled")
        case .failed(let msg): return String(localized: "Error: \(msg)")
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}
