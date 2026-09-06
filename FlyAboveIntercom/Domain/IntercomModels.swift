import Foundation

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(message: String)

    var title: String {
        switch self {
        case .disconnected: "Nincs kapcsolat"
        case .connecting: "Kapcsolódás…"
        case .connected: "Kapcsolódva"
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

    init(
        id: UUID = UUID(),
        name: String,
        detail: String,
        colorHex: String,
        isListening: Bool = true,
        isTalking: Bool = false,
        participantCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.colorHex = colorHex
        self.isListening = isListening
        self.isTalking = isTalking
        self.participantCount = participantCount
    }
}

struct IntercomConfiguration: Equatable, Sendable {
    var displayName: String
    var serverURL: URL?
    var channels: [IntercomChannel]

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
