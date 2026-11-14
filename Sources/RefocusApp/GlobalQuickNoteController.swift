import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class GlobalQuickNoteController: NSObject, NSTextFieldDelegate {
    private static let signature: OSType = 0x52464E54 // RFNT

    private let model: AppModel
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var panel: QuickNotePanel?
    private let noteField = NSTextField(string: "")
    private let saveLabel = NSTextField(labelWithString: "↩ Save")
    private let errorLabel = NSTextField(labelWithString: "")
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        super.init()
        // Build and lay out the reusable panel before the first shortcut press.
        panel = makePanel()
        observeSaveState()
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
                // Carbon application events are delivered on the main event
                // loop. Present in this event instead of queueing another task.
                MainActor.assumeIsolated { controller.toggle() }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
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
        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        focusEditor()
    }

    private func focusEditor() {
        guard noteField.isEnabled else { return }
        panel?.makeFirstResponder(noteField)
        noteField.selectText(nil)
        noteField.currentEditor()?.selectedRange = NSRange(
            location: (noteField.stringValue as NSString).length, length: 0
        )
    }

    private func makePanel() -> QuickNotePanel {
        let panel = QuickNotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 92))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.98).cgColor
        content.layer?.cornerRadius = 16
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        content.layer?.borderWidth = 1

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        noteField.placeholderString = "Quick note → dump.md"
        noteField.font = .systemFont(ofSize: 16, weight: .medium)
        noteField.textColor = .labelColor
        noteField.isBordered = false
        noteField.drawsBackground = false
        noteField.focusRingType = .none
        noteField.usesSingleLineMode = true
        noteField.cell?.isScrollable = true
        (noteField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        noteField.lineBreakMode = .byClipping
        noteField.target = self
        noteField.action = #selector(submitNote(_:))
        noteField.delegate = self
        noteField.setAccessibilityLabel("Quick note")
        saveLabel.font = .systemFont(ofSize: 11, weight: .bold)
        saveLabel.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true

        for view in [icon, noteField, saveLabel, errorLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 22),
            noteField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            noteField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            noteField.trailingAnchor.constraint(equalTo: saveLabel.leadingAnchor, constant: -10),
            saveLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            saveLabel.centerYAnchor.constraint(equalTo: noteField.centerYAnchor),
            saveLabel.widthAnchor.constraint(equalToConstant: 52),
            errorLabel.leadingAnchor.constraint(equalTo: noteField.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            errorLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        // Prepare the field editor while hidden. Typing stays inside AppKit;
        // no keystroke publishes a change to the dashboard's AppModel.
        if let editor = panel.fieldEditor(true, for: noteField) as? NSTextView {
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
        return panel
    }

    private func observeSaveState() {
        // Observe just save results, never the app clock or task list.
        model.$isSavingQuickNote.removeDuplicates().sink { [weak self] saving in
            guard let self else { return }
            self.noteField.isEnabled = !saving
            self.saveLabel.stringValue = saving ? "Saving…" : "↩ Save"
            if !saving, self.panel?.isVisible == true {
                self.focusEditor()
            }
        }.store(in: &subscriptions)
        model.$quickNoteError.combineLatest(model.$quickNoteExportIssue).sink { [weak self] saveError, exportError in
            let message = saveError ?? exportError
            self?.errorLabel.stringValue = message ?? ""
            self?.errorLabel.toolTip = message
            self?.errorLabel.isHidden = message == nil
        }.store(in: &subscriptions)
    }

    @objc private func submitNote(_ sender: Any?) {
        let accepted = model.submitQuickNote(noteField.stringValue) { [weak self] in
            self?.noteField.stringValue = ""
        }
        if accepted { panel?.orderOut(nil) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            panel?.orderOut(nil)
            return true
        }
        return false
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
