import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // ssh rilancia l'app come SSH_ASKPASS: rispondi al prompt ed esci senza aprire la UI.
        if AskPass.isActive { AskPass.run() }
        CloudFerryLiteApp.main()
    }
}

struct CloudFerryLiteApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = AppStore()
    @State private var transfers = TransferManager()

    var body: some Scene {
        WindowGroup("CloudFerryLite") {
            ContentView()
                .environment(store)
                .environment(transfers)
                .environment(store.sso)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["CLOUDFERRYLITE_SELFTEST"] == "1" {
            Task { @MainActor in exit(await SelfTest.run()) }
            return
        }
        // Solo fuori da un bundle .app (swift run): dentro un bundle ci pensa LaunchServices.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Pulisce i file temporanei di anteprima e trascinamento.
        try? FileManager.default.removeItem(at: TempFiles.root)
    }
}
