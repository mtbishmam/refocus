import Foundation

public struct PendingCaptureExport: Sendable {
    public var id: String
    public var text: String
    public var destination: String?
    public var byteOffset: Int64?
    public var suffix: Data?
}

/// Append-only output with a durable receipt, so a restart between the file
/// write and its SQLite acknowledgement cannot append the same capture twice.
public enum QuickNoteExporter {
    public static func exportPendingCaptures(from store: RefocusStore, to dumpURL: URL) throws -> Int {
        let captures = try store.pendingCaptureExports()
        var count = 0
        for capture in captures {
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            NSFileCoordinator().coordinate(
                writingItemAt: dumpURL, options: .forMerging, error: &coordinationError
            ) { coordinatedURL in
                result = Result {
                    let handle = try FileHandle(forUpdating: coordinatedURL)
                    defer { try? handle.close() }
                    let end = try handle.seekToEnd()
                    let destination = dumpURL.standardizedFileURL.path
                    let offset: UInt64
                    let suffix: Data
                    if capture.destination == destination,
                       let savedOffset = capture.byteOffset, savedOffset >= 0,
                       let savedSuffix = capture.suffix {
                        offset = UInt64(savedOffset)
                        suffix = savedSuffix
                        guard end >= offset else {
                            throw RefocusStoreError.corrupt("dump.md changed during a pending export. The note remains saved in ReFocus.")
                        }
                        try handle.seek(toOffset: offset)
                        let written = try handle.read(upToCount: suffix.count) ?? Data()
                        if written == suffix {
                            try store.markCaptureExported(id: capture.id)
                            return
                        }
                        guard end <= offset + UInt64(suffix.count), suffix.starts(with: written) else {
                            throw RefocusStoreError.corrupt("dump.md changed during a pending export. The note remains saved in ReFocus.")
                        }
                        // Resume only a verified partial append from this capture.
                        try handle.seek(toOffset: end)
                        try handle.write(contentsOf: suffix.dropFirst(written.count))
                    } else {
                        offset = end
                        let tailLength = Int(min(end, 2))
                        try handle.seek(toOffset: end - UInt64(tailLength))
                        let tail = try handle.read(upToCount: tailLength) ?? Data()
                        let separator = end == 0 || tail.suffix(2) == Data([10, 10])
                            ? "" : (tail.last == 10 ? "\n" : "\n\n")
                        suffix = Data((separator + capture.text + "\n").utf8)
                        try store.prepareCaptureExport(
                            id: capture.id, destination: destination,
                            byteOffset: Int64(offset), suffix: suffix
                        )
                        try handle.seek(toOffset: offset)
                        try handle.write(contentsOf: suffix)
                    }
                    try handle.synchronize()
                    try store.markCaptureExported(id: capture.id)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw RefocusStoreError.corrupt("Could not coordinate access to Obsidian dump.md.") }
            try result.get()
            count += 1
        }
        return count
    }
}
