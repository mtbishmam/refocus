import AVFoundation
import AppKit
import Carbon.HIToolbox

enum VoiceShortcutPreset: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case controlShiftSpace
    case optionShiftSpace

    static let defaultPreset = VoiceShortcutPreset.controlOptionSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOptionSpace: "⌃⌥Space"
        case .controlShiftSpace: "⌃⇧Space"
        case .optionShiftSpace: "⌥⇧Space"
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        case .optionShiftSpace: UInt32(optionKey | shiftKey)
        }
    }
}

private struct RecordedVoiceClip {
    var id: String
    var url: URL
    var startedAt: Date
}

@MainActor
enum VoiceMicrophoneAccess {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

@MainActor
private final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var activeClip: RecordedVoiceClip?

    func start() throws {
        guard activeClip == nil else { return }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ReFocus/VoiceQueue", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let id = UUID().uuidString.lowercased()
        let url = base.appendingPathComponent("recording-\(id).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        guard audioRecorder.prepareToRecord(), audioRecorder.record() else {
            throw OpenAIChatError.api("macOS could not start microphone recording. Check Microphone access in System Settings.")
        }
        recorder = audioRecorder
        activeClip = RecordedVoiceClip(id: id, url: url, startedAt: Date())
    }

    func stop() -> RecordedVoiceClip? {
        guard let clip = activeClip else { return nil }
        recorder?.stop()
        recorder = nil
        activeClip = nil
        guard let values = try? clip.url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 1_024 else {
            try? FileManager.default.removeItem(at: clip.url)
            return nil
        }
        return clip
    }
}

@MainActor
final class GlobalVoiceRecordingController: NSObject {
    private static let signature: OSType = 0x52465643 // RFVC
    private static let hotKeyID: UInt32 = 1

    private let model: AppModel
    private let recorder = VoiceRecorder()
    private var hotKey: EventHotKeyRef?
    private var eventHandlers: [EventHandlerRef] = []
    private var eventHandlerInstallError: OSStatus?
    private var keyIsDown = false
    private var permissionRequestGeneration = 0
    private let hud = VoiceRecordingHUD()

    init(model: AppModel) {
        self.model = model
        super.init()
        installEventHandlers()
        model.voiceShortcutChangeHandler = { [weak self] preset in
            self?.registerHotKey(preset)
        }
        registerHotKey(model.voiceShortcutPreset)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        eventHandlers.forEach { RemoveEventHandler($0) }
    }

    private func installEventHandlers() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
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
                      identifier.signature == GlobalVoiceRecordingController.signature,
                      identifier.id == GlobalVoiceRecordingController.hotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }
                let controller = Unmanaged<GlobalVoiceRecordingController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                        controller.shortcutPressed()
                    } else {
                        controller.shortcutReleased()
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            context,
            &handler
        )
        if status == noErr, let handler { eventHandlers.append(handler) }
        else { eventHandlerInstallError = status }
    }

    private func registerHotKey(_ preset: VoiceShortcutPreset) {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandlerInstallError {
            model.setVoiceShortcutStatus("Could not listen for the voice shortcut (\(eventHandlerInstallError)).")
            return
        }
        let identifier = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space), preset.carbonModifiers, identifier,
            GetApplicationEventTarget(), 0, &hotKey
        )
        model.setVoiceShortcutStatus(
            status == noErr ? "Hold \(preset.title) to record; release to transcribe." :
                "Could not register \(preset.title). Try another shortcut. (\(status))"
        )
    }

    private func shortcutPressed() {
        guard !keyIsDown else { return }
        keyIsDown = true
        permissionRequestGeneration += 1
        let generation = permissionRequestGeneration
        guard !model.voiceHasPendingTranscription, !model.voiceIsTranscribing else {
            model.setVoiceShortcutStatus("Resolve the pending voice recording in Settings before recording another.")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await VoiceMicrophoneAccess.request()
            guard self.keyIsDown, self.permissionRequestGeneration == generation else { return }
            guard granted else {
                self.keyIsDown = false
                self.model.setVoiceShortcutStatus("Allow ReFocus microphone access in System Settings to record.")
                return
            }
            do {
                try self.recorder.start()
                self.model.voiceRecordingDidStart()
                self.hud.show(shortcut: self.model.voiceShortcutPreset.title)
            } catch {
                self.keyIsDown = false
                self.model.setVoiceShortcutStatus(error.localizedDescription)
            }
        }
    }

    private func shortcutReleased() {
        keyIsDown = false
        permissionRequestGeneration += 1
        guard let clip = recorder.stop() else {
            hud.hide()
            if model.voiceIsRecording { model.voiceRecordingDidFail("The recording was too short to transcribe.") }
            return
        }
        hud.hide()
        model.voiceRecordingDidFinish(fileURL: clip.url, id: clip.id, recordedAt: clip.startedAt)
    }
}

@MainActor
private final class VoiceRecordingHUD: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "Recording…")
    private var timer: Timer?
    private var startedAt = Date()
    private var shortcut = ""

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        content.layer?.cornerRadius = 14
        content.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.65).cgColor
        content.layer?.borderWidth = 1
        let dot = NSTextField(labelWithString: "●")
        dot.textColor = .systemRed
        dot.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        for view in [dot, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
    }

    func show(shortcut: String) {
        self.shortcut = shortcut
        startedAt = Date()
        updateLabel()
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.maxY - panel.frame.height - 18))
        }
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateLabel), userInfo: nil, repeats: true)
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    @objc private func updateLabel() {
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        label.stringValue = String(format: "Recording %02d:%02d  ·  release %@ to finish", seconds / 60, seconds % 60, shortcut)
    }
}
