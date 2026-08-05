import AppKit
import SwiftUI

enum ReFocusOverlayMode {
    case planningGate
    case screenBreak
}

@MainActor
final class BreakOverlayController {
    private var panels: [NSPanel] = []
    private var model: AppModel?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var screenObserver: NSObjectProtocol?
    private(set) var mode: ReFocusOverlayMode?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.panels.isEmpty, let model = self.model, let mode = self.mode else { return }
                self.buildPanels(model: model, mode: mode)
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func showPlanning(model: AppModel) {
        show(model: model, mode: .planningGate)
    }

    func showBreak(model: AppModel) {
        // Defense in depth: never construct the screen-break panels from stale
        // UI state outside the two exact five-minute wall-clock windows.
        guard model.snapshot.phase == .screenBreak else {
            if mode == .screenBreak { hide() }
            return
        }
        show(model: model, mode: .screenBreak)
    }

    private func show(model: AppModel, mode: ReFocusOverlayMode) {
        if self.mode == mode, !panels.isEmpty { return }
        if panels.isEmpty { savedPresentationOptions = NSApp.presentationOptions }
        self.model = model
        self.mode = mode
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        buildPanels(model: model, mode: mode)
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.makeKeyAndOrderFront(nil)
        for panel in panels.dropFirst() { panel.orderFrontRegardless() }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        NSApp.presentationOptions = savedPresentationOptions
        model = nil
        mode = nil
    }

    private func buildPanels(model: AppModel, mode: ReFocusOverlayMode) {
        panels.forEach { $0.orderOut(nil) }
        let primaryScreen = NSScreen.main ?? NSScreen.screens.first
        let orderedScreens = NSScreen.screens.sorted { left, _ in left == primaryScreen }
        panels = orderedScreens.map { screen in
            let panel = KeyablePanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.backgroundColor = .black
            panel.isOpaque = true
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.canHide = false
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            let isPrimary = screen == primaryScreen
            let content: AnyView
            switch mode {
            case .planningGate:
                content = AnyView(
                    PlanningGateOverlayView(isPrimary: isPrimary)
                        .environmentObject(model)
                        .preferredColorScheme(.dark)
                )
            case .screenBreak:
                content = AnyView(
                    BreakOverlayView()
                        .environmentObject(model)
                        .preferredColorScheme(.dark)
                )
            }
            panel.contentView = NSHostingView(rootView: content)
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            return panel
        }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
