import Foundation

/// The REST surface described in `docs/API.md`.
///
/// Access tokens are passed in explicitly rather than read from a store inside
/// the client, so that `AuthService` stays the single place that decides when a
/// token is still good.
protocol IntercomAPI: Sendable {
    func login(email: String, password: String, deviceName: String) async throws -> AuthSessionResponse
    func refresh(refreshToken: String) async throws -> AuthSessionResponse
    func logout(accessToken: String) async throws
    func productions(accessToken: String) async throws -> [ProductionSummary]
    func channels(productionID: UUID, accessToken: String) async throws -> [ChannelDescriptor]
    func crew(productionID: UUID, accessToken: String) async throws -> [CrewMemberDescriptor]
    func invitePreview(code: String, accessToken: String) async throws -> InvitePreview
    func redeemInvite(code: String, accessToken: String) async throws -> ProductionSummary
    func startPrivateCall(
        productionID: UUID,
        peerID: UUID,
        accessToken: String
    ) async throws -> ChannelDescriptor
    func endPrivateCall(productionID: UUID, channelID: UUID, accessToken: String) async throws
    func realtimeTokens(
        productionID: UUID,
        channelIDs: [UUID],
        accessToken: String
    ) async throws -> RealtimeTokensResponse
}

enum APIBaseURLError: LocalizedError, Equatable {
    case notHTTP(scheme: String?)
    case insecureInRelease(host: String?)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case let .notHTTP(scheme):
            "A szerver címe nem HTTP(S): \(scheme ?? "hiányzó séma")."
        case let .insecureInRelease(host):
            "Éles buildben csak HTTPS engedélyezett (\(host ?? "ismeretlen hoszt"))."
        case let .malformed(raw):
            "A szerver címe hibás: \(raw)"
        }
    }
}

enum APIBaseURL {
    /// Parses and normalises the configured base URL.
    ///
    /// Two things matter here. The trailing slash: `URL(string:relativeTo:)`
    /// drops the last path component when it is missing, so
    /// `https://host/api` + `v1/auth/login` silently becomes
    /// `https://host/v1/auth/login`. And the scheme: development talks to a
    /// LAN server over plain HTTP, but a release build must never do that.
    static func normalised(
        _ raw: String,
        allowInsecure: Bool = APIBaseURL.allowsInsecureByDefault
    ) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            throw APIBaseURLError.malformed(raw)
        }

        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else {
            throw APIBaseURLError.notHTTP(scheme: components.scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw APIBaseURLError.malformed(raw)
        }
        if scheme == "http", !allowInsecure {
            throw APIBaseURLError.insecureInRelease(host: host)
        }

        components.scheme = scheme
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        // A base URL carries no query or fragment; keeping them would corrupt
        // every path built from it.
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { throw APIBaseURLError.malformed(raw) }
        return url
    }

    static var allowsInsecureByDefault: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

final class HTTPIntercomAPI: IntercomAPI {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .intercom) {
        self.baseURL = baseURL
        self.session = session
    }

    func login(email: String, password: String, deviceName: String) async throws -> AuthSessionResponse {
        try await send(
            path: "v1/auth/login",
            method: "POST",
            body: LoginRequest(email: email, password: password, deviceName: deviceName)
        )
    }

    func refresh(refreshToken: String) async throws -> AuthSessionResponse {
        try await send(
            path: "v1/auth/refresh",
            method: "POST",
            body: RefreshRequest(refreshToken: refreshToken)
        )
    }

    func logout(accessToken: String) async throws {
        _ = try await sendRaw(path: "v1/auth/logout", method: "POST", body: Empty?.none, accessToken: accessToken)
    }

    func productions(accessToken: String) async throws -> [ProductionSummary] {
        try await send(path: "v1/productions", method: "GET", body: Empty?.none, accessToken: accessToken)
    }

    func channels(productionID: UUID, accessToken: String) async throws -> [ChannelDescriptor] {
        try await send(
            path: "v1/productions/\(productionID.uuidString.lowercased())/channels",
            method: "GET",
            body: Empty?.none,
            accessToken: accessToken
        )
    }

    func crew(productionID: UUID, accessToken: String) async throws -> [CrewMemberDescriptor] {
        try await send(
            path: "v1/productions/\(productionID.uuidString.lowercased())/crew",
            method: "GET",
            body: Empty?.none,
            accessToken: accessToken
        )
    }

    func invitePreview(code: String, accessToken: String) async throws -> InvitePreview {
        try await send(
            path: "v1/invites/\(InviteCode.normalised(code))",
            method: "GET",
            body: Empty?.none,
            accessToken: accessToken
        )
    }

    func redeemInvite(code: String, accessToken: String) async throws -> ProductionSummary {
        let response: InviteRedemption = try await send(
            path: "v1/invites/\(InviteCode.normalised(code))/redeem",
            method: "POST",
            body: Empty?.none,
            accessToken: accessToken
        )
        return response.production
    }

    private struct PeerRequest: Encodable { let peerId: UUID }

    func startPrivateCall(
        productionID: UUID,
        peerID: UUID,
        accessToken: String
    ) async throws -> ChannelDescriptor {
        try await send(
            path: "v1/productions/\(productionID.uuidString.lowercased())/calls",
            method: "POST",
            body: PeerRequest(peerId: peerID),
            accessToken: accessToken
        )
    }

    func endPrivateCall(productionID: UUID, channelID: UUID, accessToken: String) async throws {
        _ = try await sendRaw(
            path: "v1/productions/\(productionID.uuidString.lowercased())/calls/\(channelID.uuidString.lowercased())",
            method: "DELETE",
            body: Empty?.none,
            accessToken: accessToken
        )
    }

    func realtimeTokens(
        productionID: UUID,
        channelIDs: [UUID],
        accessToken: String
    ) async throws -> RealtimeTokensResponse {
        try await send(
            path: "v1/productions/\(productionID.uuidString.lowercased())/rt-tokens",
            method: "POST",
            body: RealtimeTokensRequest(channelIds: channelIDs),
            accessToken: accessToken
        )
    }

    // MARK: - Plumbing

    private struct Empty: Encodable {}

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        accessToken: String? = nil
    ) async throws -> Response {
        let data = try await sendRaw(path: path, method: method, body: body, accessToken: accessToken)
        do {
            return try JSONDecoder.intercom.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private func sendRaw<Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        accessToken: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.intercom.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let host = baseURL.host, HostAddress.isPrivate(host), HostAddress.isUnreachable(error) {
                throw APIError.localNetworkUnreachable(host: host)
            }
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, code: nil, message: nil)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder.intercom.decode(APIErrorEnvelope.self, from: data)
            if http.statusCode == 401 {
                throw APIError.unauthorized(
                    code: envelope?.error.code,
                    message: envelope?.error.message
                )
            }
            throw APIError.http(
                status: http.statusCode,
                code: envelope?.error.code,
                message: envelope?.error.message
            )
        }

        return data
    }
}

enum HostAddress {
    /// RFC 1918 and link-local ranges, plus the local-hostname forms. These are
    /// the addresses a phone can only reach with local network permission.
    static func isPrivate(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".local") { return true }

        let parts = lowered.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (127, _): return true
        case (192, 168): return true
        case (169, 254): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }

    /// The failures that mean "nothing answered", as opposed to a server that
    /// answered badly.
    static func isUnreachable(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut,
             .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

extension URLSession {
    /// Short timeouts: an intercom that hangs for a minute is worse than one
    /// that reports a failure and lets the user retry.
    static let intercom: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
