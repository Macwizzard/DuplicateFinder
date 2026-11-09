import Cocoa

@NSApplicationMain
final class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    var mainController: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print(">>> applicationDidFinishLaunching fired")
        mainController = MainViewController()
        print(">>> mainController created")

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        print(">>> window created")
        window.title = "Duplicate Finder"
        window.contentViewController = mainController
        print(">>> contentViewController assigned")
        window.minSize = NSSize(width: 700, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)
        print(">>> makeKeyAndOrderFront called")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainController?.isScanning == true else {
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
            mainController.cancelScan()
            return .terminateNow
        } else {
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
