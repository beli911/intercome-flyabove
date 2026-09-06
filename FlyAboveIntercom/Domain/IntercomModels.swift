import Foundation

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(message: String)

    var title: String {
        switch self {
        case .disconnected: "Nincs kapcsolat"
        case .connecting: "Kapcsolódás…"
        case .connected: "Kapcsolódva"
        case .reconnecting: "Újracsatlakozás…"
        case .failed: "Kapcsolati hiba"
        }
    }
}

struct IntercomChannel: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var detail: String
    var colorHex: String
    var isListening: Bool
    var isTalking: Bool
    var participantCount: Int
    /// Server-granted permissions. The client hides what it cannot do, but the
    /// enforcement lives in the realtime token the server mints.
    var canTalk: Bool
    var canListen: Bool
    /// Someone other than us is currently speaking on this channel.
    var isRemoteSpeaking: Bool

    init(
        id: UUID = UUID(),
        name: String,
        detail: String,
        colorHex: String,
        isListening: Bool = true,
        isTalking: Bool = false,
        participantCount: Int = 0,
        canTalk: Bool = true,
        canListen: Bool = true,
        isRemoteSpeaking: Bool = false
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.colorHex = colorHex
        self.isListening = isListening
        self.isTalking = isTalking
        self.participantCount = participantCount
        self.canTalk = canTalk
        self.canListen = canListen
        self.isRemoteSpeaking = isRemoteSpeaking
    }

    init(descriptor: ChannelDescriptor) {
        self.init(
            id: descriptor.id,
            name: descriptor.name,
            detail: descriptor.detail,
            colorHex: descriptor.colorHex,
            isListening: descriptor.defaultListening && descriptor.canListen,
            participantCount: descriptor.participantCount,
            canTalk: descriptor.canTalk,
            canListen: descriptor.canListen
        )
    }
}

struct IntercomConfiguration: Equatable, Sendable {
    var displayName: String
    /// Nil until a production is selected (M2); the realtime transport cannot
    /// mint tokens without it.
    var productionID: UUID?
    var serverURL: URL?
    var channels: [IntercomChannel]

    init(
        displayName: String,
        productionID: UUID? = nil,
        serverURL: URL?,
        channels: [IntercomChannel]
    ) {
        self.displayName = displayName
        self.productionID = productionID
        self.serverURL = serverURL
        self.channels = channels
    }

    static let demo = IntercomConfiguration(
        displayName: "Operátor",
        serverURL: URL(string: "wss://intercom.flyabove.hu"),
        channels: [
            IntercomChannel(name: "Mindenki", detail: "Teljes produkció", colorHex: "5B8CFF", participantCount: 8),
            IntercomChannel(name: "Kamera", detail: "Kameraoperátorok", colorHex: "31C48D", participantCount: 4),
            IntercomChannel(name: "Rendező", detail: "Rendezői vonal", colorHex: "F59E0B", isListening: false, participantCount: 2)
        ]
    )
}

/// Connection quality figures for the developer overlay.
///
/// Named `Intercom…` rather than `TransportStatistics` because LiveKit exports a
/// type with that name.
struct IntercomStatistics: Equatable, Sendable {
    var roundTripTimeMilliseconds: Double?
    var availableOutgoingBitrateKbps: Double?
    var availableIncomingBitrateKbps: Double?
    var updatedAt: Date

    var roundTripDescription: String {
        guard let roundTripTimeMilliseconds else { return "RTT –" }
        return "RTT \(Int(roundTripTimeMilliseconds.rounded())) ms"
    }
}
