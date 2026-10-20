import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // ssh relaunches the app as SSH_ASKPASS: answer the prompt and exit without opening the UI.
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
        // Only outside an .app bundle (swift run): inside a bundle LaunchServices takes care of it.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove the temporary preview and drag-and-drop files.
        try? FileManager.default.removeItem(at: TempFiles.root)
    }
}
