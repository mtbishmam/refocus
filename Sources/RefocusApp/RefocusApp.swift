import AppKit
import SwiftUI

@MainActor
private enum ReFocusRuntime {
    // Keep one model shared by the menu-bar scene and the explicitly managed
    // dashboard window.
    static let model = AppModel()
}

@main
struct ReFocusApplication: App {
    @NSApplicationDelegateAdaptor(ReFocusAppDelegate.self) private var appDelegate

    var body: some Scene {
        // The status item and its panel are owned by the AppKit delegate.
        // A SwiftUI MenuBarExtra window is tied to a scene Space and can fail
        // to reopen when the dashboard was last shown elsewhere.
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { ReFocusRuntime.model.undoTaskChange() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!ReFocusRuntime.model.canUndoTaskChange)
                Button("Redo") { ReFocusRuntime.model.redoTaskChange() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!ReFocusRuntime.model.canRedoTaskChange)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c")
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a")
            }
        }
    }
}

@MainActor
final class ReFocusAppDelegate: NSObject, NSApplicationDelegate {
    private var globalQuickNote: GlobalQuickNoteController?
    private var statusItem: NSStatusItem?
    private var statusPanel: StatusMenuPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        globalQuickNote = GlobalQuickNoteController(model: ReFocusRuntime.model)
        // MenuBarExtra apps do not automatically instantiate ordinary windows.
        // Show the dashboard explicitly so `open ReFocus.app` has visible output.
        DispatchQueue.main.async {
            DashboardWindowController.shared.show(model: ReFocusRuntime.model)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ReFocusRuntime.model.syncCloudNow()
        DashboardWindowController.shared.show(model: ReFocusRuntime.model)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ReFocusRuntime.model.syncCloudNow()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = .removalAllowed
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "ReFocus")
        button.image?.isTemplate = true
        button.toolTip = "ReFocus"
        button.target = self
        button.action = #selector(toggleStatusPanel(_:))
        statusItem = item

        let panel = StatusMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 270),
            content: MenuContentView()
                .environmentObject(ReFocusRuntime.model)
        )
        statusPanel = panel
    }

    @objc private func toggleStatusPanel(_ sender: Any?) {
        guard let panel = statusPanel, let button = statusItem?.button else { return }
        if panel.isVisible {
            panel.orderOut(sender)
            button.isHighlighted = false
        } else {
            let size = panel.frame.size
            guard let statusWindow = button.window else { return }
            let buttonRect = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = statusWindow.screen ?? NSScreen.screens.first
            let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            let x = min(
                max(buttonRect.midX - size.width / 2, (visibleFrame?.minX ?? 0) + 8),
                (visibleFrame?.maxX ?? size.width + 8) - size.width - 8
            )
            let y = buttonRect.minY - size.height - 8
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            // Move to the Space from which the status item was clicked. This
            // is the behavior used by menu-bar utilities such as Maccy.
            panel.collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
            panel.orderFrontRegardless()
            panel.makeKey()
            button.isHighlighted = true
        }
    }
}

private final class StatusMenuPanel: NSPanel {
    init<Content: View>(contentRect: NSRect, content: Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .none
        hidesOnDeactivate = false
        isFloatingPanel = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = NSHostingView(
            rootView: content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}
