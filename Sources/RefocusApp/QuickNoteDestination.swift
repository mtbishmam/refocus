import Foundation

enum QuickNoteDestination {
    private static let bookmarkKey = "refocus.quickNote.dumpBookmark"
    static let suggestedURL = URL(fileURLWithPath:
        "/Users/mtbishmam/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian/dump.md"
    )

    static func save(_ url: URL) throws {
        guard url.lastPathComponent == "dump.md" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func resolve() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale
        )
        if stale {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try save(url)
        }
        return url
    }
}

struct QuickNoteExportStatus: Sendable {
    var destination: String?
    var pending: Int
    var issue: String?

    var message: String {
        if let issue { return issue }
        return pending == 0 ? "All saved notes exported to dump.md." : "\(pending) notes waiting to export."
    }
}
