import Foundation

/// A signaling and realtime-media implementation boundary.
///
/// The first milestone uses `PreviewIntercomTransport`. A production transport can
/// implement this protocol with WebRTC without changing the UI or domain model.
protocol IntercomTransport: Sendable {
    func connect(configuration: IntercomConfiguration) async throws
    func disconnect() async
    func setListening(_ enabled: Bool, channelID: UUID) async throws
    func setTalking(_ enabled: Bool, channelID: UUID) async throws
}

enum IntercomTransportError: LocalizedError {
    case invalidServerURL
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "A szerver címe hibás."
        case .notConnected: "Nincs aktív kapcsolat a szerverrel."
        }
    }
}
