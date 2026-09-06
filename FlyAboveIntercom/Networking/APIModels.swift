import Foundation

// MARK: - Coding

extension JSONDecoder {
    /// Every date on the wire is RFC 3339 / ISO 8601 with fractional seconds.
    static let intercom: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601DateFormatter.intercom.date(from: raw)
                ?? ISO8601DateFormatter.intercomWithoutFraction.date(from: raw)
            else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Nem értelmezhető időbélyeg: \(raw)"
                )
            }
            return date
        }
        return decoder
    }()
}

extension JSONEncoder {
    static let intercom: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.intercom.string(from: date))
        }
        return encoder
    }()
}

extension ISO8601DateFormatter {
    // Configured once and only ever read; parsing is thread-safe.
    nonisolated(unsafe) static let intercom: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let intercomWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Auth

struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
    let deviceName: String
}

struct RefreshRequest: Encodable, Sendable {
    let refreshToken: String
}

struct AuthenticatedUser: Codable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let email: String
}

struct AuthSessionResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    /// Lifetime of `accessToken` in seconds, relative to the moment of the response.
    let expiresIn: TimeInterval
    let user: AuthenticatedUser

    func tokens(now: Date = .now) -> AuthTokens {
        AuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: now.addingTimeInterval(expiresIn),
            user: user
        )
    }
}

// MARK: - Productions and channels

struct ProductionSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    /// `operator`, `supervisor` or `admin`; drives what M2 exposes in the UI.
    let role: String
}

struct ChannelDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let detail: String
    let colorHex: String
    let canTalk: Bool
    let canListen: Bool
    let defaultListening: Bool
    let participantCount: Int
}

// MARK: - Realtime

/// A LiveKit join credential for exactly one channel.
///
/// One channel is one LiveKit room, so permissions are enforced by the server
/// when it mints the token rather than by the client honouring a flag.
struct RealtimeGrant: Decodable, Equatable, Sendable {
    let channelId: UUID
    let roomName: String
    let token: String
    let expiresAt: Date
    let canPublish: Bool
    let canSubscribe: Bool
}

struct RealtimeTokensRequest: Encodable, Sendable {
    let channelIds: [UUID]
}

struct RealtimeTokensResponse: Decodable, Equatable, Sendable {
    /// LiveKit websocket endpoint, e.g. `wss://rt.intercom.flyabove.hu`.
    let url: URL
    let grants: [RealtimeGrant]
}

// MARK: - Errors

struct APIErrorEnvelope: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        let code: String
        let message: String
    }

    let error: Body
}

enum APIError: LocalizedError {
    case invalidBaseURL
    case unauthorized
    case http(status: Int, code: String?, message: String?)
    case transport(any Error)
    case decoding(any Error)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "A szerver címe hibás."
        case .unauthorized:
            "A bejelentkezés lejárt, jelentkezz be újra."
        case let .http(status, _, message):
            message ?? "A szerver hibát adott (HTTP \(status))."
        case let .transport(error):
            "Hálózati hiba: \(error.localizedDescription)"
        case .decoding:
            "A szerver válasza nem értelmezhető."
        }
    }
}
