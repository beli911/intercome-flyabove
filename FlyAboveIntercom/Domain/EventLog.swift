import Foundation

/// What happened, in the operator's own session.
///
/// This exists because "it dropped out once around the second half" is not
/// something anyone can act on. A soak test or an incident review needs times
/// and codes.
///
/// What it may contain is deliberately narrow, and matches `docs/SECURITY.md`:
/// connection states, error codes, channel names, quality figures. Never a
/// token, never a TURN credential, never audio. It lives in memory, is bounded,
/// and is not written to disk — a log that outlives the session is a retention
/// question nobody has answered yet.
@MainActor
final class EventLog: ObservableObject {
    enum Severity: Sendable {
        case info
        case warning
        case error
    }

    enum Code: String, Sendable {
        case connected
        case disconnected
        case reconnecting
        case connectionFailed
        case microphoneGranted
        case microphoneDenied
        case talkStoppedBySystem
        case interrupted
        case routeChanged
        case mediaServicesReset
        case configurationChanged
        case privateCallStarted
        case privateCallEnded
        case failsafeDisconnect

        var title: String {
            switch self {
            case .connected: "KAPCSOLÓDVA"
            case .disconnected: "BONTVA"
            case .reconnecting: "ÚJRACSATLAKOZÁS"
            case .connectionFailed: "KAPCSOLATI HIBA"
            case .microphoneGranted: "MIKROFON ENGEDÉLYEZVE"
            case .microphoneDenied: "MIKROFON MEGTAGADVA"
            case .talkStoppedBySystem: "TALK LEÁLLÍTVA"
            case .interrupted: "MEGSZAKÍTÁS"
            case .routeChanged: "HANGÚTVONAL VÁLTÁS"
            case .mediaServicesReset: "HANGSZOLGÁLTATÁS ÚJRAINDULT"
            case .configurationChanged: "KONFIGURÁCIÓ FRISSÜLT"
            case .privateCallStarted: "PRIVÁT HÍVÁS INDULT"
            case .privateCallEnded: "PRIVÁT HÍVÁS VÉGE"
            case .failsafeDisconnect: "BIZTONSÁGI BONTÁS"
            }
        }
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id = UUID()
        let date: Date
        let severity: Severity
        let code: Code
        /// Human-readable context. Channel names and figures only.
        let detail: String?

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    }

    /// Newest first: an operator looking at this wants the last thing that
    /// happened, not the first.
    @Published private(set) var entries: [Entry] = []

    private let limit: Int
    private let now: @Sendable () -> Date

    init(limit: Int = 200, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.now = now
    }

    func record(_ code: Code, severity: Severity = .info, detail: String? = nil) {
        entries.insert(
            Entry(date: now(), severity: severity, code: code, detail: detail),
            at: 0
        )
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Errors and warnings since the session began, for the header summary.
    var problemCount: Int {
        entries.count { $0.severity != .info }
    }
}
