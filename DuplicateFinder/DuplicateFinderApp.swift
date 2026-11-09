import SwiftUI
import AppKit

/// Shared state between the SwiftUI view and the AppDelegate.
/// The delegate needs to know whether a scan is in progress (to prompt before
/// quitting) and needs a way to cancel it.
final class ScanState: ObservableObject {
    @Published var isScanning: Bool = false
    /// Called by the AppDelegate (or the Cancel button) to stop an in-flight scan.
    var cancelHandler: (() -> Void)?
}

@main
struct DuplicateFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var scanState = ScanState()

    var body: some Scene {
        WindowGroup("Duplicate Finder") {
            ContentView(scanState: scanState)
                .frame(minWidth: 800, minHeight: 550)
                .onAppear { appDelegate.scanState = scanState }
        }
        .windowStyle(.titleBar)
    }
}

/// Intercepts Quit so we can warn the user when a scan is running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var scanState: ScanState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let scanState, scanState.isScanning else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "A scan is in progress."
        alert.informativeText = "Quitting now will cancel the scan. Any files already trashed will stay in the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Scan & Quit")
        alert.addButton(withTitle: "Continue Scanning")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // User chose to quit — cancel the scan and let termination proceed.
            scanState.cancelHandler?()
            return .terminateNow
        } else {
            // User chose to keep scanning. Abort the termination.
            return .terminateCancel
        }
    }
}
