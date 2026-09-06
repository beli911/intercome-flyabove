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
    func realtimeTokens(
        productionID: UUID,
        channelIDs: [UUID],
        accessToken: String
    ) async throws -> RealtimeTokensResponse
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
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, code: nil, message: nil)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let envelope = try? JSONDecoder.intercom.decode(APIErrorEnvelope.self, from: data)
            throw APIError.http(
                status: http.statusCode,
                code: envelope?.error.code,
                message: envelope?.error.message
            )
        }

        return data
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
