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
    @StateObject private var model = ReFocusRuntime.model
    @NSApplicationDelegateAdaptor(ReFocusAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView().environmentObject(model)
        } label: {
            MenuBarClockLabel(clock: model.clockDisplay)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarClockLabel: View {
    @ObservedObject var clock: ClockDisplay

    var body: some View {
        Label(
            String(format: "%02d:%02d", clock.snapshot.secondsRemaining / 60, clock.snapshot.secondsRemaining % 60),
            systemImage: clock.snapshot.phase == .focus ? "timer" : "eye.slash"
        )
    }
}

@MainActor
final class ReFocusAppDelegate: NSObject, NSApplicationDelegate {
    private var globalQuickNote: GlobalQuickNoteController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        globalQuickNote = GlobalQuickNoteController(model: ReFocusRuntime.model)
        // MenuBarExtra apps do not automatically instantiate ordinary windows.
        // Show the dashboard explicitly so `open ReFocus.app` has visible output.
        DispatchQueue.main.async {
            DashboardWindowController.shared.show(model: ReFocusRuntime.model)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DashboardWindowController.shared.show(model: ReFocusRuntime.model)
        return true
    }
}
