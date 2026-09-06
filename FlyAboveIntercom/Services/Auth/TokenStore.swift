import Foundation
import Security

/// The credentials issued by the FlyAbove intercom API.
///
/// `accessToken` is a short-lived bearer token for the REST API. `refreshToken`
/// is long-lived and is the only value that survives an app restart in a useful
/// state, so both are stored together in the Keychain.
struct AuthTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var accessTokenExpiresAt: Date

    /// Treats a token that expires within `leeway` as already expired so a
    /// refresh happens before a request can fail mid-flight.
    func isExpired(now: Date = .now, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= accessTokenExpiresAt
    }
}

protocol TokenStoring: Sendable {
    func load() throws -> AuthTokens?
    func save(_ tokens: AuthTokens) throws
    func clear() throws
}

enum TokenStoreError: LocalizedError, Equatable {
    case keychainFailure(OSStatus)
    case corruptedPayload

    var errorDescription: String? {
        switch self {
        case let .keychainFailure(status):
            "A biztonságos tároló hibát adott (\(status))."
        case .corruptedPayload:
            "A tárolt bejelentkezési adat sérült, jelentkezz be újra."
        }
    }
}

/// Keychain-backed store.
///
/// The item uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: the app has
/// the `audio` background mode and may need to reconnect while the screen is
/// locked, but the credential must never travel to another device via backup.
final class KeychainTokenStore: TokenStoring {
    private let service: String
    private let account: String

    init(service: String = "hu.flyabove.intercom.auth", account: String = "primary") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func load() throws -> AuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw TokenStoreError.corruptedPayload }
            do {
                return try JSONDecoder.intercom.decode(AuthTokens.self, from: data)
            } catch {
                // A payload we cannot read is worse than none: drop it so the
                // next login can write a clean item.
                try? clear()
                throw TokenStoreError.corruptedPayload
            }
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.keychainFailure(status)
        }
    }

    func save(_ tokens: AuthTokens) throws {
        let data = try JSONEncoder.intercom.encode(tokens)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TokenStoreError.keychainFailure(updateStatus)
        }

        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStoreError.keychainFailure(addStatus)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychainFailure(status)
        }
    }
}

/// Used by previews and unit tests, where the Keychain is either unavailable or
/// shared process-wide state we do not want tests to depend on.
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    init(tokens: AuthTokens? = nil) { self.tokens = tokens }

    func load() throws -> AuthTokens? {
        lock.withLock { tokens }
    }

    func save(_ tokens: AuthTokens) throws {
        lock.withLock { self.tokens = tokens }
    }

    func clear() throws {
        lock.withLock { tokens = nil }
    }
}
