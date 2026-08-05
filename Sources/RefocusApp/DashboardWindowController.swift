import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController {
    static let shared = DashboardWindowController()

    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = DashboardView().environmentObject(model)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ReFocus"
        window.contentViewController = controller
        window.minSize = NSSize(width: 860, height: 620)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
