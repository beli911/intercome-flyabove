import Foundation

/// Something the transport learned on its own, without the UI asking.
enum IntercomTransportEvent: Sendable {
    case connectionStateChanged(ConnectionState)
    case participantCountChanged(channelID: UUID, count: Int)
    case remoteSpeakingChanged(channelID: UUID, isSpeaking: Bool)
    /// The server dropped our publish permission, or the local track died; the
    /// UI must release the Talk button.
    case talkStopped(channelID: UUID)
    case statistics(IntercomStatistics)
}

/// A signaling and realtime-media implementation boundary.
///
/// `PreviewIntercomTransport` keeps the app runnable without a server;
/// `LiveKitIntercomTransport` is the production implementation. Neither is
/// visible to the UI or the domain model.
protocol IntercomTransport: Sendable {
    func connect(configuration: IntercomConfiguration) async throws
    func disconnect() async
    func setListening(_ enabled: Bool, channelID: UUID) async throws
    func setTalking(_ enabled: Bool, channelID: UUID) async throws
    /// Long-lived stream of transport-originated updates. Called once per
    /// connection lifetime by the view model.
    func events() async -> AsyncStream<IntercomTransportEvent>
}

extension IntercomTransport {
    /// Transports that never report anything on their own (test spies, the
    /// preview transport) do not have to implement this.
    func events() async -> AsyncStream<IntercomTransportEvent> {
        AsyncStream { $0.finish() }
    }
}

enum IntercomTransportError: LocalizedError {
    case invalidServerURL
    case notConnected
    case missingProduction
    case unknownChannel
    case notPermittedToTalk
    case realtime(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "A szerver címe hibás."
        case .notConnected: "Nincs aktív kapcsolat a szerverrel."
        case .missingProduction: "Nincs kiválasztva produkció."
        case .unknownChannel: "Ismeretlen csatorna."
        case .notPermittedToTalk: "Ezen a csatornán nincs beszédjogosultságod."
        case let .realtime(message): message
        }
    }
}
