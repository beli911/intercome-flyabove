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
    /// Playout gain, 1.0 being unity. Per-channel level is how an operator
    /// keeps the director audible under a busy camera line.
    var volume: Double
    /// What the channel is for; drives the ducking rules.
    var role: ChannelRole
    /// An ephemeral one-to-one line, named after the other person.
    var isPrivate: Bool
    /// How far this channel steps back when it is ducked.
    var duckDecibels: Double
    /// Who is on this line right now.
    var participants: [ChannelParticipant]

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
        isRemoteSpeaking: Bool = false,
        volume: Double = 1.0,
        role: ChannelRole = .line,
        isPrivate: Bool = false,
        duckDecibels: Double = 12,
        participants: [ChannelParticipant] = []
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
        self.volume = volume
        self.role = role
        self.isPrivate = isPrivate
        self.duckDecibels = duckDecibels
        self.participants = participants
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
            canListen: descriptor.canListen,
            role: descriptor.role ?? .line,
            isPrivate: descriptor.isPrivate ?? false,
            duckDecibels: descriptor.duckDecibels ?? 12
        )
    }
}

struct IntercomConfiguration: Equatable, Sendable {
    var displayName: String
    var productionName: String = ""

    /// Nil until a production is selected (M2); the realtime transport cannot
    /// mint tokens without it.
    var productionID: UUID?
    var serverURL: URL?
    var channels: [IntercomChannel]

    init(
        displayName: String,
        productionName: String = "",
        productionID: UUID? = nil,
        serverURL: URL?,
        channels: [IntercomChannel]
    ) {
        self.displayName = displayName
        self.productionName = productionName
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

/// How the Talk control behaves.
///
/// Momentary is the safe default: the microphone cannot stay open by accident,
/// because holding the button is what keeps it open. Latch exists because an
/// operator whose hands are on a camera cannot hold anything.
enum TalkMode: String, CaseIterable, Identifiable, Sendable {
    case momentary
    case latch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .momentary: "MOMENTARY"
        case .latch: "LATCH"
        }
    }

    var explanation: String {
        switch self {
        case .momentary: "Tartsd nyomva. Felengedve azonnal zár."
        case .latch: "Koppintásra beragad, újra koppintásra zár."
        }
    }
}

/// How well one participant's link is holding up.
enum LinkQuality: Int, Comparable, Sendable {
    case unknown = 0
    case lost
    case poor
    case good
    case excellent

    static func < (lhs: LinkQuality, rhs: LinkQuality) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .unknown: "—"
        case .lost: "MEGSZAKADT"
        case .poor: "GYENGE"
        case .good: "JÓ"
        case .excellent: "KIVÁLÓ"
        }
    }
}

/// Somebody the transport can see on a channel right now.
struct ChannelParticipant: Identifiable, Equatable, Sendable {
    /// The server-issued user id, as LiveKit identity.
    let id: String
    var displayName: String
    var isSpeaking: Bool
    var quality: LinkQuality
}

/// A member of the production, whether or not they are connected.
///
/// Two sources meet here: the roster comes from the API (who belongs to this
/// production and in what role), presence comes from the realtime transport
/// (who is actually on a line, and who is talking). Neither alone is the crew.
struct CrewMember: Identifiable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var role: String
    var isOnline: Bool
    var isSpeaking: Bool
    var quality: LinkQuality
    /// Channels this person is currently heard on.
    var activeChannelIDs: [UUID]

    var initials: String {
        let words = displayName.split(separator: " ")
        switch words.count {
        case 0: return "??"
        case 1: return String(words[0].prefix(2)).uppercased()
        default: return String(words.prefix(2).compactMap(\.first)).uppercased()
        }
    }
}

/// Dark by default: most of this work happens in a gallery or a truck. Daylight
/// mode exists because an outside broadcast in sun is unreadable otherwise.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "SÖTÉT"
        case .light: "NAPFÉNY"
        case .auto: "AUTO"
        }
    }
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
