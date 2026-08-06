import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class GlobalQuickNoteController {
    private static let signature: OSType = 0x52464E54 // RFNT

    private let model: AppModel
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var panel: QuickNotePanel?

    init(model: AppModel) {
        self.model = model
        installHotKey()
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func installHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr,
                      identifier.signature == GlobalQuickNoteController.signature,
                      identifier.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let controller = Unmanaged<GlobalQuickNoteController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in controller.toggle() }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(controlKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    private func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: GlobalQuickNoteView { [weak panel] in
                panel?.orderOut(nil)
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
        )
        position(panel)
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // The global key-down event is still being dispatched while this runs.
        // Repeat activation just after it finishes so the previous application
        // cannot reclaim keyboard focus from the capture field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak panel] in
            guard let panel, panel.isVisible else { return }
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel() -> QuickNotePanel {
        let panel = QuickNotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 74),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - size.width - 18,
            y: visibleFrame.maxY - size.height - 10
        ))
    }
}

private final class QuickNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct GlobalQuickNoteView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var isFocused: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.title3.bold())
                .foregroundStyle(.orange)
            TextField("Quick note → dump.md", text: $model.quickNote)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .focused($isFocused)
                .onSubmit {
                    let hasText = !model.quickNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    guard hasText else { return }
                    model.submitQuickNote()
                    dismiss()
                }
            Text("↩ Save")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(width: 460, height: 74)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.18)))
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
        .onExitCommand { dismiss() }
    }
}
