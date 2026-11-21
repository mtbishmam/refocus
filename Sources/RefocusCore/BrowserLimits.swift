import Foundation

public struct BrowserLimitSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var minutesPerRollingHour: Int
    public var trackedDomains: [String]

    public init(
        enabled: Bool = false,
        minutesPerRollingHour: Int = 5,
        trackedDomains: [String] = ["facebook.com", "instagram.com"]
    ) {
        self.enabled = enabled
        self.minutesPerRollingHour = min(60, max(1, minutesPerRollingHour))
        self.trackedDomains = Self.normalizedDomains(trackedDomains)
    }

    public static let `default` = BrowserLimitSettings()

    public var limitSeconds: Int { minutesPerRollingHour * 60 }

    public static func normalizedDomains(_ domains: [String]) -> [String] {
        var seen: Set<String> = []
        return domains.compactMap { raw in
            var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !candidate.isEmpty else { return nil }
            if let components = URLComponents(string: candidate),
               let host = components.host, !host.isEmpty {
                candidate = host
            } else {
                candidate = candidate.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? candidate
            }
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if candidate.hasPrefix("www.") { candidate.removeFirst(4) }
            guard candidate.contains("."),
                  !candidate.contains(where: { $0.isWhitespace }),
                  candidate.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil,
                  !seen.contains(candidate) else { return nil }
            seen.insert(candidate)
            return candidate
        }
    }

    public func trackedDomain(for host: String) -> String? {
        let cleanHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trackedDomains.first { domain in
            cleanHost == domain || cleanHost.hasSuffix("." + domain)
        }
    }
}

public struct BrowserUsageSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var host: String
    public var browserBundleID: String
    public var browserName: String
    public var startedAt: Date
    public var lastSeenAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(), host: String, browserBundleID: String,
        browserName: String, startedAt: Date, lastSeenAt: Date,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.host = host
        self.browserBundleID = browserBundleID
        self.browserName = browserName
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
        self.endedAt = endedAt
    }
}

public struct ClosedBrowserTab: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var browserBundleID: String
    public var browserName: String
    public var closedAt: Date

    public init(
        id: UUID = UUID(), url: String, title: String,
        browserBundleID: String, browserName: String, closedAt: Date
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.browserBundleID = browserBundleID
        self.browserName = browserName
        self.closedAt = closedAt
    }
}

public enum BrowserUsagePolicy {
    public static func remainingSeconds(
        limitSeconds: Int,
        reportedUsageSeconds: Int,
        trackingActive: Bool,
        sampledAt: Date,
        now: Date
    ) -> Int {
        let liveSeconds = trackingActive
            ? max(0, Int(now.timeIntervalSince(sampledAt)))
            : 0
        return max(0, limitSeconds - max(0, reportedUsageSeconds) - liveSeconds)
    }

    public static func seconds(
        in sessions: [BrowserUsageSession],
        since windowStart: Date,
        through now: Date,
        activeSessionID: UUID? = nil
    ) -> Int {
        guard now > windowStart else { return 0 }
        let total = sessions.reduce(TimeInterval.zero) { result, session in
            let effectiveEnd: Date
            if session.id == activeSessionID {
                effectiveEnd = now
            } else {
                effectiveEnd = session.endedAt ?? session.lastSeenAt
            }
            let start = max(session.startedAt, windowStart)
            let end = min(effectiveEnd, now)
            return result + max(0, end.timeIntervalSince(start))
        }
        return Int(total.rounded(.down))
    }
}
