import Foundation

/// What a channel is for. Ducking rules follow from this, so the production
/// declares intent once instead of the client guessing from names.
enum ChannelRole: String, Codable, Sendable {
    /// An ordinary talkback line.
    case line
    /// Programme audio. This is what gets dipped so a cue can be heard over it
    /// — the "IFB" in interruptible foldback.
    case program
    /// The director's line. When this one speaks, everything else steps back.
    case priority

    var title: String {
        switch self {
        case .line: "VONAL"
        case .program: "PROGRAM FEED"
        case .priority: "PRIORITÁS"
        }
    }
}

/// Decides which channels step back, and by how much.
///
/// Pulled out as a pure function on purpose: this is the one piece of audio
/// behaviour where being wrong is inaudible until it matters, and it needs to
/// be exhaustively testable without a transport or a room.
enum DuckingPolicy {
    struct Input: Equatable, Sendable {
        /// Someone other than us is speaking on a priority line.
        var isPriorityActive: Bool
        /// We are transmitting somewhere.
        var isSelfTalking: Bool
    }

    /// Multiplier applied on top of the operator's own level.
    static func gainMultiplier(
        for role: ChannelRole,
        input: Input,
        duckDecibels: Double
    ) -> Double {
        guard shouldDuck(role: role, input: input) else { return 1 }
        return pow(10, -abs(duckDecibels) / 20)
    }

    static func shouldDuck(role: ChannelRole, input: Input) -> Bool {
        switch role {
        case .priority:
            // The line that causes ducking is never itself ducked; that is the
            // whole point of it.
            return false
        case .program:
            // Programme audio steps back both for the director and for our own
            // transmission: talking over a feed you cannot hear yourself under
            // is how people shout.
            return input.isPriorityActive || input.isSelfTalking
        case .line:
            // Ordinary lines only step back for the director. Ducking them
            // while we talk would mute the very people we are talking to.
            return input.isPriorityActive
        }
    }
}
