import Foundation

/// Deterministic local transport used while the server contract is being built.
actor PreviewIntercomTransport: IntercomTransport {
    private var isConnected = false

    func connect(configuration: IntercomConfiguration) async throws {
        guard configuration.serverURL != nil else {
            throw IntercomTransportError.invalidServerURL
        }
        try await Task.sleep(for: .milliseconds(450))
        isConnected = true
    }

    func disconnect() async {
        isConnected = false
    }

    func setListening(_ enabled: Bool, channelID: UUID) async throws {
        guard isConnected else { throw IntercomTransportError.notConnected }
    }

    func setTalking(_ enabled: Bool, channelID: UUID) async throws {
        guard isConnected else { throw IntercomTransportError.notConnected }
    }
}
