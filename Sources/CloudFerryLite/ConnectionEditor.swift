import SwiftUI

struct ConnectionEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(SSOService.self) private var sso
    @Environment(\.dismiss) private var dismiss

    @State var connection: Connection
    let isNew: Bool

    @State private var secret = ""
    @State private var clearSecret = false
    @State private var manualBuckets = ""
    @State private var portText = ""
    @State private var testing = false
    @State private var testResult: Result<String, Error>?
    @State private var profiles: [AWSProfile] = []
    @State private var ssoAccounts: [SSOAccount] = []
    @State private var ssoRoles: [String] = []
    @State private var ssoBusy = false
    @State private var ssoError: String?

    private var hasStoredSecret: Bool { !isNew && Keychain.secret(for: connection.id) != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $connection.kind) {
                        Text("S3").tag(ConnectionKind.s3)
                        Text("SFTP / SSH").tag(ConnectionKind.sftp)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!isNew)
                    TextField("Name", text: $connection.name)
                }
                switch connection.kind {
                case .s3: s3Sections
                case .sftp: sftpSections
                }
                if let testResult {
                    Section {
                        switch testResult {
                        case .success(let msg): Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failure(let err): Label(err.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Test connection") { Task { await test() } }
                    .disabled(testing || !isValid)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 540, height: 540)
        .onAppear {
            manualBuckets = connection.manualBuckets.joined(separator: ", ")
            portText = connection.port.map(String.init) ?? ""
            profiles = AWSProfile.load()
        }
    }

    // MARK: S3

    @ViewBuilder
    private var s3Sections: some View {
        Section {
            TextField("Endpoint", text: $connection.endpoint, prompt: Text("empty = AWS S3, e.g. https://minio.local:9000"))
                .onChange(of: connection.endpoint) { old, new in
                    // S3-compatible services almost always use path-style.
                    if old.isEmpty && !new.isEmpty { connection.usePathStyle = true }
                }
            TextField("Region", text: $connection.region, prompt: Text("us-east-1"))
            Toggle("Path-style (endpoint/bucket/key)", isOn: $connection.usePathStyle)
        }
        Section("Credentials") {
            Picker("Authentication", selection: $connection.s3Auth) {
                Text("Access key").tag(S3AuthMethod.accessKey)
                Text("AWS SSO (Identity Center)").tag(S3AuthMethod.sso)
            }
            switch connection.s3Auth {
            case .accessKey:
                TextField("Access Key ID", text: $connection.accessKeyID)
                SecureField("Secret Access Key", text: $secret,
                            prompt: Text(hasStoredSecret ? "leave empty to keep it" : ""))
            case .sso:
                ssoFields
            }
            if !profiles.isEmpty {
                Menu("Import from ~/.aws profile") {
                    ForEach(profiles) { p in
                        Button(p.isSSO ? "\(p.name) (SSO)" : p.name) { apply(p) }
                    }
                }
            }
        }
        Section("Bucket") {
            Toggle("Credentials can list buckets", isOn: $connection.canListBuckets)
            TextField("Buckets (comma separated)", text: $manualBuckets,
                      prompt: Text(connection.canListBuckets ? "optional, used if listing fails" : "required"))
        }
    }

    @ViewBuilder
    private var ssoFields: some View {
        TextField("Start URL", text: $connection.ssoStartURL, prompt: Text("https://my-org.awsapps.com/start"))
        TextField("SSO region", text: $connection.ssoRegion, prompt: Text("eu-west-1"))
        if ssoAccounts.isEmpty {
            TextField("Account ID", text: $connection.ssoAccountID)
        } else {
            Picker("Account", selection: $connection.ssoAccountID) {
                ForEach(ssoAccounts) { Text("\($0.accountName) · \($0.accountId)").tag($0.accountId) }
            }
            .onChange(of: connection.ssoAccountID) { _, _ in Task { await loadRoles() } }
        }
        if ssoRoles.isEmpty {
            TextField("Role", text: $connection.ssoRoleName)
        } else {
            Picker("Role", selection: $connection.ssoRoleName) {
                ForEach(ssoRoles, id: \.self) { Text($0).tag($0) }
            }
        }
        HStack {
            Button(ssoAccounts.isEmpty ? "Sign in and choose account/role…" : "Refresh list") { Task { await loadAccounts() } }
                .disabled(ssoBusy || connection.ssoStartURL.isEmpty || connection.ssoRegion.isEmpty)
            if ssoBusy { ProgressView().controlSize(.small) }
        }
        if let prompt = sso.prompt {
            Label("Confirm the code \(prompt.userCode) in the browser", systemImage: "person.badge.key")
                .font(.callout.monospaced())
        }
        if let ssoError { Text(ssoError).font(.caption).foregroundStyle(.red) }
    }

    // MARK: SFTP

    @ViewBuilder
    private var sftpSections: some View {
        Section {
            TextField("Host", text: $connection.host, prompt: Text("server.example.com or a ~/.ssh/config alias"))
            TextField("Port", text: $portText, prompt: Text("22 or from ~/.ssh/config"))
            TextField("User", text: $connection.username, prompt: Text("from ~/.ssh/config or local user"))
            TextField("Start folder", text: $connection.startPath, prompt: Text("optional, e.g. /var/www"))
        }
        Section("Authentication") {
            Picker("Method", selection: $connection.sftpAuth) {
                Text("SSH key / agent").tag(SFTPAuthMethod.key)
                Text("Password").tag(SFTPAuthMethod.password)
            }
            switch connection.sftpAuth {
            case .key:
                HStack {
                    TextField("Private key", text: $connection.identityFile, prompt: Text("optional: ~/.ssh, agent and config"))
                    Button("Choose…") { chooseKey() }
                }
                SecureField("Passphrase", text: $secret,
                            prompt: Text(hasStoredSecret ? "saved, leave empty to keep it" : "optional, asked when needed"))
            case .password:
                SecureField("Password", text: $secret,
                            prompt: Text(hasStoredSecret ? "saved, leave empty to keep it" : "optional, asked when needed"))
            }
            if hasStoredSecret {
                Toggle("Remove the secret saved in the Keychain", isOn: $clearSecret)
            }
            Text("The connection uses /usr/bin/ssh: ~/.ssh/config, ssh-agent, known_hosts and ProxyJump all apply. Unknown host keys must be confirmed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Logic

    private var isValid: Bool {
        guard !connection.name.isEmpty else { return false }
        switch connection.kind {
        case .sftp:
            return !connection.host.trimmingCharacters(in: .whitespaces).isEmpty && (portText.isEmpty || Int(portText) != nil)
        case .s3:
            let creds: Bool
            switch connection.s3Auth {
            case .accessKey: creds = !connection.accessKeyID.isEmpty && (!secret.isEmpty || hasStoredSecret)
            case .sso: creds = !connection.ssoStartURL.isEmpty && !connection.ssoRegion.isEmpty
                && !connection.ssoAccountID.isEmpty && !connection.ssoRoleName.isEmpty
            }
            return creds && (connection.canListBuckets || !parsedBuckets.isEmpty)
        }
    }

    private var parsedBuckets: [String] {
        manualBuckets.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
    }

    private func apply(_ p: AWSProfile) {
        if p.isSSO {
            connection.s3Auth = .sso
            connection.ssoStartURL = p.ssoStartURL ?? ""
            connection.ssoRegion = p.ssoRegion ?? ""
            connection.ssoAccountID = p.ssoAccountID ?? ""
            connection.ssoRoleName = p.ssoRoleName ?? ""
        } else {
            connection.s3Auth = .accessKey
            connection.accessKeyID = p.accessKeyID ?? ""
            secret = p.secretAccessKey ?? ""
        }
        if let r = p.region { connection.region = r }
        if let e = p.endpoint { connection.endpoint = e; connection.usePathStyle = true }
        if connection.name == Connection.defaultName { connection.name = p.name }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connection.identityFile = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func loadAccounts() async {
        ssoBusy = true
        defer { ssoBusy = false }
        ssoError = nil
        do {
            let c = normalized()
            ssoAccounts = try await sso.accounts(startURL: c.ssoStartURL, region: c.ssoRegion)
            if !ssoAccounts.contains(where: { $0.accountId == connection.ssoAccountID }) {
                connection.ssoAccountID = ssoAccounts.first?.accountId ?? ""
            }
            await loadRoles()
        } catch {
            ssoError = error.localizedDescription
        }
    }

    private func loadRoles() async {
        guard !connection.ssoAccountID.isEmpty else { return }
        do {
            let c = normalized()
            ssoRoles = try await sso.roles(startURL: c.ssoStartURL, region: c.ssoRegion, accountID: c.ssoAccountID)
            if !ssoRoles.contains(connection.ssoRoleName) { connection.ssoRoleName = ssoRoles.first ?? "" }
        } catch {
            ssoError = error.localizedDescription
        }
    }

    private func normalized() -> Connection {
        var c = connection
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        c.endpoint = trim(c.endpoint)
        c.region = trim(c.region).isEmpty ? "us-east-1" : trim(c.region)
        c.accessKeyID = trim(c.accessKeyID)
        c.manualBuckets = parsedBuckets
        c.ssoStartURL = trim(c.ssoStartURL)
        c.ssoRegion = trim(c.ssoRegion)
        c.ssoAccountID = trim(c.ssoAccountID)
        c.ssoRoleName = trim(c.ssoRoleName)
        c.host = trim(c.host)
        c.username = trim(c.username)
        c.port = Int(trim(portText))
        c.identityFile = trim(c.identityFile)
        c.startPath = trim(c.startPath)
        return c
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let c = normalized()
        // The test uses the secret just typed without saving it: for SFTP it goes through a temporary Keychain item.
        var probe = c
        if c.kind == .sftp { probe.id = UUID() }
        let tempSecret = secret.isEmpty ? (clearSecret ? nil : Keychain.secret(for: c.id)) : secret
        if c.kind == .sftp, let tempSecret { Keychain.setSecret(tempSecret, for: probe.id) }
        defer { if c.kind == .sftp { Keychain.deleteSecret(for: probe.id) } }
        do {
            let backend: any RemoteBackend
            if c.kind == .s3 && c.s3Auth == .accessKey {
                backend = S3Backend(client: S3Client(connection: c, credentials:
                    AWSCredentials(accessKeyID: c.accessKeyID, secretAccessKey: tempSecret ?? "")))
            } else {
                backend = try await AppStore.makeBackend(probe, sso: sso)
            }
            defer { backend.close() }
            if c.kind == .s3, !c.canListBuckets, let first = c.manualBuckets.first {
                _ = try await backend.listPage(bucket: first, prefix: "", token: nil)
                testResult = .success(String(localized: "Connected: \(first) is accessible"))
            } else {
                let roots = try await backend.roots()
                testResult = .success(c.kind == .s3 ? String(localized: "Connected: \(roots.count) buckets")
                                                    : String(localized: "Connected: home is \("/" + (roots.first { $0.systemImage == "house" }?.prefix ?? ""))"))
            }
        } catch {
            testResult = .failure(error)
        }
    }

    private func save() {
        let c = normalized()
        let newSecret: String? = clearSecret ? "" : (secret.isEmpty ? nil : secret)
        store.upsert(c, secret: newSecret)
        dismiss()
    }
}
