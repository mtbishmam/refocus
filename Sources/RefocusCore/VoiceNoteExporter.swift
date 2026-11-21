import Foundation

public struct PendingVoiceNoteExport: Sendable {
    public var id: String
    public var day: String
    public var recordedAt: Date
    public var text: String
    public var destination: String?
    public var byteOffset: Int64?
    public var suffix: Data?
}

public struct VoiceNoteExportStatus: Sendable {
    public var destination: String?
    public var pending: Int
    public var issue: String?

    public init(destination: String?, pending: Int, issue: String?) {
        self.destination = destination
        self.pending = pending
        self.issue = issue
    }

    public var message: String {
        if let issue { return issue }
        if pending == 0 { return "All voice notes are exported to dump.md." }
        return "\(pending) transcript\(pending == 1 ? "" : "s") waiting to export."
    }
}

/// Appends queued transcripts to the selected Obsidian dump.md.
/// A byte-range receipt makes retries safe if the process stops after writing
/// the file but before acknowledging the export in SQLite.
public enum VoiceNoteExporter {
    @discardableResult
    public static func exportPendingVoiceNotes(
        from store: RefocusStore,
        to dumpURL: URL,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) throws -> Int {
        let notes = try store.pendingVoiceNoteExports()
        guard !notes.isEmpty else { return 0 }

        var exported = 0

        for note in notes {
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(
                writingItemAt: dumpURL,
                options: .forMerging,
                error: &coordinationError
            ) { coordinatedURL in
                result = Result {
                    let handle = try FileHandle(forUpdating: coordinatedURL)
                    defer { try? handle.close() }
                    let end = try handle.seekToEnd()
                    let destination = dumpURL.standardizedFileURL.path
                    let offset: UInt64
                    let suffix: Data

                    if note.destination == destination,
                       let savedOffset = note.byteOffset, savedOffset >= 0,
                       let savedSuffix = note.suffix {
                        offset = UInt64(savedOffset)
                        suffix = savedSuffix
                        guard end >= offset else {
                            throw RefocusStoreError.corrupt("dump.md changed during a pending voice-note export. The transcript remains saved in ReFocus.")
                        }
                        try handle.seek(toOffset: offset)
                        let written = try handle.read(upToCount: suffix.count) ?? Data()
                        if written == suffix {
                            try handle.synchronize()
                            try store.markVoiceNoteExported(id: note.id)
                            return
                        }
                        guard end <= offset + UInt64(suffix.count), suffix.starts(with: written) else {
                            throw RefocusStoreError.corrupt("dump.md changed during a pending voice-note export. The transcript remains saved in ReFocus.")
                        }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: suffix.dropFirst(written.count))
                    } else {
                        offset = end
                        let tailLength = Int(min(end, 2))
                        try handle.seek(toOffset: end - UInt64(tailLength))
                        let tail = try handle.read(upToCount: tailLength) ?? Data()
                        let separator = end == 0 || tail.suffix(2) == Data([10, 10])
                            ? "" : (tail.last == 10 ? "\n" : "\n\n")
                        let timestamp = Self.formatTimestamp(note.recordedAt, calendar: calendar)
                        suffix = Data((separator + "## Voice Note — \(timestamp)\n\n\(note.text)\n").utf8)
                        try store.prepareVoiceNoteExport(
                            id: note.id,
                            destination: destination,
                            byteOffset: Int64(offset),
                            suffix: suffix
                        )
                        try handle.seek(toOffset: offset)
                        try handle.write(contentsOf: suffix)
                    }

                    try handle.synchronize()
                    try store.markVoiceNoteExported(id: note.id)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else {
                throw RefocusStoreError.corrupt("Could not coordinate access to Obsidian dump.md.")
            }
            try result.get()
            exported += 1
        }
        return exported
    }
    private static func formatTimestamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
