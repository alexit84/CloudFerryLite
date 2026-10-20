import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(SSOService.self) private var sso
    @State private var selection: SidebarItem?
    @State private var browser = BrowserModel()
    @State private var editing: Connection?
    @State private var expanded: Set<UUID> = []
    @State private var renamingFavorite: Favorite?
    @State private var favoriteName = ""
    @State private var deletingConnection: Connection?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            BrowserView(model: browser)
        }
        .sheet(item: $editing) { conn in
            ConnectionEditor(connection: conn, isNew: store.connection(conn.id) == nil)
        }
        .sheet(item: Binding(get: { editing == nil ? sso.prompt : nil }, set: { _ in })) { prompt in
            SSOPromptView(prompt: prompt)
        }
        .onChange(of: selection) { _, item in open(item) }
        .onChange(of: store.connections.map(\.id)) { _, ids in
            // Connection deleted while it was open.
            if let loc = browser.location, !ids.contains(loc.connectionID) {
                browser.reset()
                selection = nil
            }
        }
        .alert("Rename favorite", isPresented: Binding(get: { renamingFavorite != nil },
                                                          set: { if !$0 { renamingFavorite = nil } })) {
            TextField("Name", text: $favoriteName)
            Button("Rename") {
                if let f = renamingFavorite, !favoriteName.isEmpty { store.renameFavorite(f.id, to: favoriteName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the connection \"\(deletingConnection?.name ?? "")\"?",
                            isPresented: Binding(get: { deletingConnection != nil },
                                                 set: { if !$0 { deletingConnection = nil } })) {
            Button("Delete", role: .destructive) {
                if let c = deletingConnection { store.delete(c.id) }
            }
        } message: {
            Text("Its favorites and the secrets stored in the Keychain will be removed too.")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Favorites") {
                if store.favorites.isEmpty {
                    Text("Use the ☆ in the toolbar to add buckets or folders")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.favorites) { fav in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fav.name)
                            Text("\(store.connection(fav.connectionID)?.name ?? "?") · \(fav.bucket)/\(fav.prefix)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                    .tag(SidebarItem.favorite(fav.id))
                    .contextMenu {
                        Button("Rename…") { favoriteName = fav.name; renamingFavorite = fav }
                        Button("Remove from Favorites", role: .destructive) { store.removeFavorite(fav.id) }
                    }
                }
                .onMove { store.moveFavorites(from: $0, to: $1) }
            }

            Section("Connections") {
                ForEach(store.connections) { conn in
                    DisclosureGroup(isExpanded: expansion(conn.id)) {
                        rootRows(conn)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(conn.name)
                                Text(conn.displayEndpoint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: conn.systemImage)
                        }
                        .contextMenu {
                            Button(conn.kind == .s3 ? "Refresh buckets" : "Reconnect") { Task { await store.loadRoots(conn.id) } }
                            if conn.kind == .s3, conn.s3Auth == .sso {
                                Button("Sign out of SSO") { sso.logout(startURL: conn.ssoStartURL) }
                            }
                            Button("Edit…") { editing = conn }
                            Divider()
                            Button("Delete…", role: .destructive) { deletingConnection = conn }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    editing = Connection(name: Connection.defaultName)
                } label: {
                    Label("New connection", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
        .onAppear {
            if store.connections.isEmpty { editing = Connection(name: Connection.defaultName) }
        }
    }

    @ViewBuilder
    private func rootRows(_ conn: Connection) -> some View {
        if store.loadingRoots.contains(conn.id) && store.roots[conn.id] == nil {
            ProgressView().controlSize(.small)
        }
        if let err = store.rootErrors[conn.id] {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).lineLimit(4)
        }
        ForEach(store.roots[conn.id] ?? []) { root in
            Label(root.name, systemImage: root.systemImage)
                .tag(SidebarItem.root(conn.id, root.bucket, root.prefix))
                .contextMenu {
                    let loc = BrowseLocation(connectionID: conn.id, bucket: root.bucket, prefix: root.prefix)
                    Button(store.favorite(for: loc) == nil ? "Add to Favorites" : "Remove from Favorites") {
                        store.toggleFavorite(loc)
                    }
                    Button("Copy name") { copy(conn.kind == .s3 ? root.bucket : "/" + root.prefix) }
                }
        }
        if store.roots[conn.id]?.isEmpty == true && store.rootErrors[conn.id] == nil {
            Text("No buckets").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding {
            expanded.contains(id)
        } set: { open in
            if open {
                expanded.insert(id)
                if store.roots[id] == nil { Task { await store.loadRoots(id) } }
            } else {
                expanded.remove(id)
            }
        }
    }

    private func open(_ item: SidebarItem?) {
        switch item {
        case .favorite(let id):
            guard let f = store.favorites.first(where: { $0.id == id }) else { return }
            browser.open(BrowseLocation(connectionID: f.connectionID, bucket: f.bucket, prefix: f.prefix), store: store)
        case .root(let conn, let bucket, let prefix):
            browser.open(BrowseLocation(connectionID: conn, bucket: bucket, prefix: prefix), store: store)
        case nil:
            break
        }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Code to confirm in the browser during the AWS SSO sign-in.
struct SSOPromptView: View {
    let prompt: SSOLoginPrompt
    @Environment(SSOService.self) private var sso

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key").font(.system(size: 36)).foregroundStyle(.tint)
            Text("AWS SSO sign-in").font(.headline)
            Text("In the browser, confirm that the code shown is:")
                .font(.callout).foregroundStyle(.secondary)
            Text(prompt.userCode)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Text(prompt.startURL).font(.caption).foregroundStyle(.secondary)
            ProgressView().controlSize(.small)
            HStack {
                Button("Cancel") { sso.cancelLogin() }
                Button("Open the browser again") { NSWorkspace.shared.open(prompt.verificationURL) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
