import AppKit
import Foundation
import RefocusCore

struct BrowserLimitMonitorState: Sendable {
    var usedSeconds: Int
    var activeDomain: String?
    var message: String
    var closedTabs: [ClosedBrowserTab]
    var sampledAt: Date
}

private struct ActiveBrowserTab: Sendable {
    var url: String
    var title: String
    var host: String
    var bundleID: String
    var browserName: String
}

private enum BrowserAutomationError: LocalizedError {
    case automationDenied(String)
    case script(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied(let browser):
            "Allow ReFocus to control \(browser) in System Settings → Privacy & Security → Automation."
        case .script(let message): message
        }
    }
}

private enum BrowserAppleEvents {
    static let supported: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.brave.Browser": "Brave Browser",
        "com.apple.Safari": "Safari",
    ]

    static func activeTab(bundleID: String) throws -> ActiveBrowserTab? {
        guard let browserName = supported[bundleID] else { return nil }
        let script: String
        if bundleID == "com.apple.Safari" {
            script = """
            tell application id "\(bundleID)"
              if (count of windows) = 0 then return ""
              set currentTab to current tab of front window
              return (URL of currentTab) & (ASCII character 10) & (name of currentTab)
            end tell
            """
        } else {
            script = """
            tell application id "\(bundleID)"
              if (count of windows) = 0 then return ""
              set currentTab to active tab of front window
              return (URL of currentTab) & (ASCII character 10) & (title of currentTab)
            end tell
            """
        }
        let output = try run(script, browserName: browserName)
        guard !output.isEmpty else { return nil }
        let pieces = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let urlText = String(pieces.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlText),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        return ActiveBrowserTab(
            url: url.absoluteString,
            title: pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "",
            host: host,
            bundleID: bundleID,
            browserName: browserName
        )
    }

    static func closeActiveTab(bundleID: String, expectedURL: String) throws -> Bool {
        guard let browserName = supported[bundleID] else { return false }
        let expected = appleScriptString(expectedURL)
        let tabExpression = bundleID == "com.apple.Safari"
            ? "current tab of front window" : "active tab of front window"
        let script = """
        tell application id "\(bundleID)"
          if (count of windows) = 0 then return "changed"
          set currentTab to \(tabExpression)
          if (URL of currentTab) is \(expected) then
            close currentTab
            return "closed"
          end if
          return "changed"
        end tell
        """
        return try run(script, browserName: browserName) == "closed"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ source: String, browserName: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw BrowserAutomationError.script("Could not prepare browser control for \(browserName).")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if code == -1743 || code == -1002 || code == 1002 {
                throw BrowserAutomationError.automationDenied(browserName)
            }
            let detail = error[NSAppleScript.errorMessage] as? String
            throw BrowserAutomationError.script(detail.map { "\(browserName): \($0)" } ?? "Could not read the active tab in \(browserName).")
        }
        return result.stringValue ?? ""
    }
}

actor BrowserLimitMonitor {
    private let worker: VaultWorker
    private let onState: @MainActor @Sendable (BrowserLimitMonitorState) -> Void
    private var settings = BrowserLimitSettings.default
    private var currentSession: BrowserUsageSession?
    private var lastHeartbeatAt: Date?
    private var lastPublishedAt = Date.distantPast
    private var lastPublishedSeconds = -1
    private var closedTabs: [ClosedBrowserTab] = []
    private var isPolling = false

    init(
        worker: VaultWorker,
        onState: @escaping @MainActor @Sendable (BrowserLimitMonitorState) -> Void
    ) {
        self.worker = worker
        self.onState = onState
    }

    func prepare() async {
        do {
            try await worker.prepareBrowserUsageTracking()
            closedTabs = try await worker.recentClosedBrowserTabs()
        } catch {
            await publish(used: 0, domain: nil, message: "Browser limit storage is unavailable: \(error.localizedDescription)")
        }
    }

    func configure(_ settings: BrowserLimitSettings) async {
        self.settings = settings
        if !settings.enabled { await endSession(at: Date()) }
        lastPublishedSeconds = -1
        await poll(frontmostBundleID: nil)
    }

    func poll(frontmostBundleID: String?) async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        let now = Date()

        guard settings.enabled, !settings.trackedDomains.isEmpty else {
            await endSession(at: now)
            await publish(used: 0, domain: nil, message: "Website limits are off; no browser URLs are being read.")
            return
        }

        guard let bundleID = frontmostBundleID,
              BrowserAppleEvents.supported[bundleID] != nil else {
            await endSession(at: now)
            let usage = await usage(at: now, activeID: nil)
            await publish(used: usage, domain: nil, message: "Watching the active tab in Chrome, Brave, or Safari; background browsers do not count.")
            return
        }

        let tab: ActiveBrowserTab?
        do {
            tab = try BrowserAppleEvents.activeTab(bundleID: bundleID)
        } catch {
            await endSession(at: now)
            let usage = await usage(at: now, activeID: nil)
            await publish(used: usage, domain: nil, message: error.localizedDescription)
            return
        }

        guard let tab, let domain = settings.trackedDomain(for: tab.host) else {
            await endSession(at: now)
            let usage = await usage(at: now, activeID: nil)
            await publish(used: usage, domain: nil, message: "\(usage.formattedDuration) of \(settings.minutesPerRollingHour):00 used this rolling hour across Chrome, Brave, and Safari.")
            return
        }

        if currentSession?.host != tab.host || currentSession?.browserBundleID != tab.bundleID {
            await endSession(at: now)
            let session = BrowserUsageSession(
                host: tab.host, browserBundleID: tab.bundleID, browserName: tab.browserName,
                startedAt: now, lastSeenAt: now
            )
            do {
                try await worker.beginBrowserUsageSession(session)
                currentSession = session
                lastHeartbeatAt = now
            } catch {
                await publish(used: 0, domain: domain, message: "Could not save local browser usage: \(error.localizedDescription)")
                return
            }
        }

        guard let session = currentSession else { return }
        if let lastHeartbeatAt, now.timeIntervalSince(lastHeartbeatAt) >= 15 {
            do {
                try await worker.heartbeatBrowserUsageSession(session.id, at: now)
                currentSession?.lastSeenAt = now
                self.lastHeartbeatAt = now
            } catch {
                await publish(used: 0, domain: domain, message: "Could not update local browser usage: \(error.localizedDescription)")
                return
            }
        }

        let used = await usage(at: now, activeID: session.id)
        if used >= settings.limitSeconds {
            do {
                let closedTab = ClosedBrowserTab(
                    url: tab.url, title: tab.title, browserBundleID: tab.bundleID,
                    browserName: tab.browserName, closedAt: now
                )
                // Persist the exact URL before attempting closure so a full
                // disk or app exit cannot lose the link after the tab closes.
                try await worker.saveClosedBrowserTab(closedTab)
                let closed: Bool
                do {
                    closed = try BrowserAppleEvents.closeActiveTab(bundleID: tab.bundleID, expectedURL: tab.url)
                } catch {
                    try? await worker.removeClosedBrowserTab(id: closedTab.id)
                    throw error
                }
                guard closed else {
                    try? await worker.removeClosedBrowserTab(id: closedTab.id)
                    await publish(used: used, domain: domain, message: "The active tab changed before ReFocus could close it. No other tab was closed.")
                    return
                }
                closedTabs = (try? await worker.recentClosedBrowserTabs()) ?? ([closedTab] + closedTabs)
                await endSession(at: now)
                await publish(used: used, domain: domain, message: "Hourly limit reached. Closed and saved the active \(domain) tab from \(tab.browserName).")
                return
            } catch {
                await publish(used: used, domain: domain, message: "Limit reached, but ReFocus couldn't close this tab: \(error.localizedDescription)")
                return
            }
        }

        let shouldPublish = now.timeIntervalSince(lastPublishedAt) >= 5 || used != lastPublishedSeconds
        if shouldPublish {
            await publish(
                used: used, domain: domain,
                message: "\(used.formattedDuration) of \(settings.minutesPerRollingHour):00 used this rolling hour (\(domain) · \(tab.browserName))."
            )
        }
    }

    private func usage(at now: Date, activeID: UUID?) async -> Int {
        (try? await worker.browserUsageSeconds(
            inLast: 3_600, at: now, activeSessionID: activeID
        )) ?? 0
    }

    private func endSession(at date: Date) async {
        guard let session = currentSession else { return }
        try? await worker.finishBrowserUsageSession(session.id, at: date)
        currentSession = nil
        lastHeartbeatAt = nil
    }

    private func publish(used: Int, domain: String?, message: String) async {
        lastPublishedAt = Date()
        lastPublishedSeconds = used
        await onState(BrowserLimitMonitorState(
            usedSeconds: used, activeDomain: domain, message: message,
            closedTabs: closedTabs, sampledAt: lastPublishedAt
        ))
    }
}

private extension Int {
    var formattedDuration: String {
        String(format: "%d:%02d", self / 60, self % 60)
    }
}
