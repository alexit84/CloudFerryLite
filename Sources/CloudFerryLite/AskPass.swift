import AppKit

/// SSH_ASKPASS mode: ssh relaunches the app executable with the prompt as argument and reads the answer from stdout.
/// - password: from the connection's Keychain item (if any), otherwise asked with a dialog;
/// - key passphrase: from the Keychain if saved, otherwise a dialog;
/// - unknown host key confirmation: dialog with the fingerprint shown by ssh.
enum AskPass {
    static let modeKey = "CLOUDFERRYLITE_ASKPASS"
    static let connectionKey = "CLOUDFERRYLITE_ASKPASS_CONNECTION"
    static let authKey = "CLOUDFERRYLITE_ASKPASS_AUTH"
    static let titleKey = "CLOUDFERRYLITE_ASKPASS_TITLE"
    /// Language of the app that launched ssh, so the dialogs match it.
    static let languageKey = "CLOUDFERRYLITE_ASKPASS_LANGUAGE"

    static var isActive: Bool { ProcessInfo.processInfo.environment[modeKey] == "1" }

    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        // Volatile argument domain: affects only this helper process, nothing is persisted.
        if let lang = env[languageKey] {
            UserDefaults.standard.setVolatileDomain(["AppleLanguages": [lang]], forName: UserDefaults.argumentDomain)
        }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        let title = env[titleKey] ?? "CloudFerryLite"
        let lower = prompt.lowercased()
        let stored = env[connectionKey].flatMap(UUID.init(uuidString:)).flatMap(Keychain.secret(for:))

        if lower.contains("yes/no") {
            let ok = confirm(title: String(localized: "Unknown SSH host — \(title)"), text: prompt)
            answer(ok ? "yes" : nil)
        }
        if lower.contains("passphrase") {
            // With key authentication the saved secret is the passphrase.
            if env[authKey] == SFTPAuthMethod.key.rawValue, let stored, !stored.isEmpty { answer(stored) }
            answer(ask(title: title, text: prompt, secure: true))
        }
        if lower.contains("password") {
            if env[authKey] == SFTPAuthMethod.password.rawValue, let stored, !stored.isEmpty { answer(stored) }
            answer(ask(title: title, text: prompt, secure: true))
        }
        // Other keyboard-interactive prompts (e.g. an OTP code).
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

    /// The dialog comes from a background process: keep it above the other windows.
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
