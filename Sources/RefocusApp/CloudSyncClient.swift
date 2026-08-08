import Foundation
import RefocusCore
import Security

enum CloudSyncError: LocalizedError {
    case server(action: String, status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .server(let action, let status, let message):
            return "\(action) failed (HTTP \(status)): \(message)"
        }
    }
}

struct CloudSyncResult: Sendable {
    var isPaired: Bool
    var pulledEntities: Int
    var pushedMutations: Int
    var cursor: Int
    var pendingMutations: Int
    var issue: String?

    static let notPaired = CloudSyncResult(
        isPaired: false, pulledEntities: 0, pushedMutations: 0,
        cursor: 0, pendingMutations: 0, issue: nil
    )

    var changedLocally: Bool { pulledEntities > 0 }
}

enum CloudCredentials {
    // Keep credentials scoped to the canonical mtbishmam Site so tokens from
    // the retired Bari-owned deployment can never be sent to the new D1.
    private static let service = "site.chatgpt.mtbishmam.refocus.canonical"
    private static let tokenAccount = "sync-token"
    private static let bypassAccount = "sites-bypass-token"

    struct Values {
        let apiToken: String
        let sitesBypassToken: String
    }

    static func load() -> Values? {
        guard let apiToken = load(account: tokenAccount),
              let bypassToken = load(account: bypassAccount),
              !apiToken.isEmpty, !bypassToken.isEmpty else { return nil }
        return Values(apiToken: apiToken, sitesBypassToken: bypassToken)
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func savePairingValue(_ value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("rfp_") else {
            throw NSError(
                domain: "ReFocusPairing", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Generate a new Mac pairing token from ReFocus Web."]
            )
        }
        var encoded = String(clean.dropFirst(4)).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count.isMultiple(of: 4) == false { encoded.append("=") }
        struct Bundle: Decodable { let apiToken: String; let sitesBypassToken: String }
        guard let data = Data(base64Encoded: encoded),
              let bundle = try? JSONDecoder().decode(Bundle.self, from: data),
              !bundle.apiToken.isEmpty, !bundle.sitesBypassToken.isEmpty else {
            throw NSError(
                domain: "ReFocusPairing", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The Mac pairing token is invalid."]
            )
        }
        try save(bundle.apiToken, account: tokenAccount)
        try save(bundle.sitesBypassToken, account: bypassAccount)
    }

    static func clear() throws {
        try save("", account: tokenAccount)
        try save("", account: bypassAccount)
    }

    private static func save(_ token: String, account: String) throws {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary)
        guard !clean.isEmpty else { return }
        var item = identity
        item[kSecValueData as String] = Data(clean.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct CloudSyncClient: Sendable {
    static let baseURL = URL(string: "https://refocus.mtbishmam.chatgpt.site")!
    static let targetIdentifier = baseURL.absoluteString

    func sync(store: RefocusStore) async -> CloudSyncResult {
        guard let credentials = CloudCredentials.load() else { return .notPaired }
        var pulled = 0
        var pushed = 0
        do {
            if try store.prepareCloudTarget(Self.targetIdentifier) > 0 {
                UserDefaults.standard.set(0, forKey: "cloudSyncCursor")
            }
            pulled += try await pull(store: store, credentials: credentials)
        } catch {
            return result(store: store, paired: true, pulled: pulled, pushed: pushed, issue: error.localizedDescription)
        }

        var uploadIssue: String?
        while true {
            let pending: [Data]
            do { pending = try store.pendingMutations(limit: 5) }
            catch {
                uploadIssue = error.localizedDescription
                break
            }
            if pending.isEmpty { break }
            do {
                let objects = try pending.map { data -> Any in try JSONSerialization.jsonObject(with: data) }
                let body = try JSONSerialization.data(withJSONObject: ["mutations": objects])
                var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/sync/push"))
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                authorize(&request, with: credentials)
                let (responseData, response) = try await URLSession.shared.data(for: request)
                try requireSuccess(responseData, response: response, action: "Sync upload")
                let ids = objects.compactMap { ($0 as? [String: Any])?["mutationId"] as? String }
                try store.acknowledgeMutations(ids)
                pushed += ids.count
            } catch {
                uploadIssue = error.localizedDescription
                break
            }
        }

        // Pull once more after uploads so the local database reflects the
        // server's field-level merge, including edits made by another device.
        do { pulled += try await pull(store: store, credentials: credentials) }
        catch { if uploadIssue == nil { uploadIssue = error.localizedDescription } }
        return result(store: store, paired: true, pulled: pulled, pushed: pushed, issue: uploadIssue)
    }

    private func pull(store: RefocusStore, credentials: CloudCredentials.Values) async throws -> Int {
        let cursor = UserDefaults.standard.integer(forKey: "cloudSyncCursor")
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("api/sync/pull"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cursor", value: String(cursor))]
        var request = URLRequest(url: components.url!)
        authorize(&request, with: credentials)
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(data, response: response, action: "Sync download")
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try store.applyRemotePull(data)
        if let next = payload?["cursor"] as? Int {
            UserDefaults.standard.set(next, forKey: "cloudSyncCursor")
        }
        return (payload?["entities"] as? [Any] ?? []).count
    }

    private func result(
        store: RefocusStore, paired: Bool, pulled: Int, pushed: Int, issue: String?
    ) -> CloudSyncResult {
        let pending = (try? store.pendingMutations(limit: 10_000).count) ?? 0
        return CloudSyncResult(
            isPaired: paired, pulledEntities: pulled, pushedMutations: pushed,
            cursor: UserDefaults.standard.integer(forKey: "cloudSyncCursor"),
            pendingMutations: pending, issue: issue
        )
    }

    func validateConnection() async throws {
        guard let credentials = CloudCredentials.load() else {
            throw CloudSyncError.server(action: "Pairing", status: 0, message: "Credentials are missing.")
        }
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("api/sync/pull"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cursor", value: String(UserDefaults.standard.integer(forKey: "cloudSyncCursor")))]
        var request = URLRequest(url: components.url!)
        authorize(&request, with: credentials)
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(data, response: response, action: "Pairing")
    }

    func acquireExportLease(deviceID: String) async throws -> Bool {
        guard let credentials = CloudCredentials.load() else { return true }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/export-lease"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["deviceId": deviceID])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, with: credentials)
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(data, response: response, action: "Export lease")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return payload["acquired"] as? Bool ?? false
    }

    private func authorize(_ request: inout URLRequest, with credentials: CloudCredentials.Values) {
        request.setValue("Bearer \(credentials.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "Bearer \(credentials.sitesBypassToken)",
            forHTTPHeaderField: "OAI-Sites-Authorization"
        )
    }

    private func requireSuccess(_ data: Data, response: URLResponse, action: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudSyncError.server(action: action, status: 0, message: "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = object?["error"] as? String
                ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Unknown server response."
            throw CloudSyncError.server(action: action, status: http.statusCode, message: message)
        }
    }
}
