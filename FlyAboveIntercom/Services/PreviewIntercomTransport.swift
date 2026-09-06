import Foundation

/// Offline transport for demo mode and SwiftUI previews.
///
/// It reports the same events as the real transport so the UI can be exercised
/// without a server; it simply never carries audio.
actor PreviewIntercomTransport: IntercomTransport {
    private var isConnected = false
    private var continuations: [UUID: AsyncStream<IntercomTransportEvent>.Continuation] = [:]

    func connect(configuration: IntercomConfiguration) async throws {
        guard configuration.serverURL != nil else {
            throw IntercomTransportError.invalidServerURL
        }
        emit(.connectionStateChanged(.connecting))
        try await Task.sleep(for: .milliseconds(450))
        isConnected = true
        emit(.connectionStateChanged(.connected))
    }

    func disconnect() async {
        isConnected = false
        emit(.connectionStateChanged(.disconnected))
    }

    func setListening(_ enabled: Bool, channelID: UUID) async throws {
        guard isConnected else { throw IntercomTransportError.notConnected }
    }

    func setTalking(_ enabled: Bool, channelID: UUID) async throws {
        guard isConnected else { throw IntercomTransportError.notConnected }
    }

    func setVolume(_: Double, channelID _: UUID) async throws {
        guard isConnected else { throw IntercomTransportError.notConnected }
    }

    func setDucking(_: Double, channelID _: UUID) async throws {
        guard isConnected else { throw IntercomTransportError.notConnected }
    }

    func events() async -> AsyncStream<IntercomTransportEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: IntercomTransportEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }
}
