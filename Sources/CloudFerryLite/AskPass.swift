import AppKit

/// Modalità SSH_ASKPASS: ssh rilancia l'eseguibile dell'app con il prompt come argomento e legge la risposta da stdout.
/// - password: dal Keychain della connessione (se c'è), altrimenti chiesta con un dialog;
/// - passphrase della chiave: dal Keychain se salvata, altrimenti dialog;
/// - conferma host key sconosciuta: dialog con l'impronta mostrata da ssh.
enum AskPass {
    static let modeKey = "CLOUDFERRYLITE_ASKPASS"
    static let connectionKey = "CLOUDFERRYLITE_ASKPASS_CONNECTION"
    static let authKey = "CLOUDFERRYLITE_ASKPASS_AUTH"
    static let titleKey = "CLOUDFERRYLITE_ASKPASS_TITLE"

    static var isActive: Bool { ProcessInfo.processInfo.environment[modeKey] == "1" }

    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        let title = env[titleKey] ?? "CloudFerryLite"
        let lower = prompt.lowercased()
        let stored = env[connectionKey].flatMap(UUID.init(uuidString:)).flatMap(Keychain.secret(for:))

        if lower.contains("yes/no") {
            let ok = confirm(title: String(localized: "Unknown SSH host — \(title)"), text: prompt)
            answer(ok ? "yes" : nil)
        }
        if lower.contains("passphrase") {
            // Con autenticazione a chiave il segreto salvato è la passphrase.
            if env[authKey] == SFTPAuthMethod.key.rawValue, let stored, !stored.isEmpty { answer(stored) }
            answer(ask(title: title, text: prompt, secure: true))
        }
        if lower.contains("password") {
            if env[authKey] == SFTPAuthMethod.password.rawValue, let stored, !stored.isEmpty { answer(stored) }
            answer(ask(title: title, text: prompt, secure: true))
        }
        // Altri prompt keyboard-interactive (es. codice OTP).
        answer(ask(title: title, text: prompt, secure: false))
    }

    private static func answer(_ value: String?) -> Never {
        guard let value else { exit(1) }
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
        exit(0)
    }

    private static func prepareApp() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
    }

    /// Il dialog nasce da un processo in background: tienilo sopra le altre finestre.
    private static func float(_ alert: NSAlert) {
        alert.window.level = .floating
        alert.window.orderFrontRegardless()
    }

    private static func confirm(title: String, text: String) -> Bool {
        prepareApp()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        float(alert)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func ask(title: String, text: String, secure: Bool) -> String? {
        prepareApp()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        float(alert)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
