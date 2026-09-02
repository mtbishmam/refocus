import AppKit
import SwiftUI

enum ReFocusOverlayMode {
    case planningGate
    case rest
    case screenBreak
}

@MainActor
final class BreakOverlayController {
    private var panels: [NSPanel] = []
    private var model: AppModel?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
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
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.panels.isEmpty, let model = self.model, let mode = self.mode else { return }
                self.buildPanels(model: model, mode: mode)
                self.bringPanelsToFront()
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
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

    func showRest(model: AppModel) {
        show(model: model, mode: .rest)
    }

    private func show(model: AppModel, mode: ReFocusOverlayMode) {
        if self.mode == mode, !panels.isEmpty {
            bringPanelsToFront()
            return
        }
        if panels.isEmpty { savedPresentationOptions = NSApp.presentationOptions }
        self.model = model
        self.mode = mode
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        buildPanels(model: model, mode: mode)
        bringPanelsToFront()
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
            // Full-screen apps occupy their own Space. A level above the
            // standard screen-saver tier plus all-Spaces/full-screen-auxiliary
            // behavior keeps the blocker above those windows as Spaces change.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
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
            case .rest:
                content = AnyView(
                    RestGateOverlayView(isPrimary: isPrimary)
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

    private func bringPanelsToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for panel in panels {
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.orderFrontRegardless()
        }
        panels.first?.makeKeyAndOrderFront(nil)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
