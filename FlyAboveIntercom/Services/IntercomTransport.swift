import Foundation

/// One room's link health, expressed without LiveKit's types so the
/// aggregation rule can be tested on its own.
enum RoomLinkState: Sendable, Equatable {
    case connecting
    case connected
    case reconnecting
    case disconnected
}

enum ConnectionAggregation {
    /// Green means *every* joined line is up.
    ///
    /// A channel that has dropped while the others are fine is exactly the case
    /// an operator must see: hidden behind a healthy room, it is how a cue gets
    /// missed. Anything short of all-connected therefore reads as reconnecting.
    static func state(from rooms: [RoomLinkState]) -> ConnectionState {
        guard !rooms.isEmpty else { return .disconnected }
        if rooms.allSatisfy({ $0 == .connected }) { return .connected }
        if rooms.allSatisfy({ $0 == .disconnected }) { return .disconnected }
        return .reconnecting
    }
}

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
    ///
    /// Must be `async`: an actor implementing this with a synchronous method
    /// silently fails to witness the requirement, and every caller then gets an
    /// empty stream instead of a compile error.
    func events() async -> AsyncStream<IntercomTransportEvent>
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
