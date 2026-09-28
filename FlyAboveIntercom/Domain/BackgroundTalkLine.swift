import Foundation

/// Which line the operator can talk on with the phone locked, or another app in
/// front of ours.
///
/// The shape of this file is forced by a system constraint, not by taste: iOS
/// lets an app hold **one** Push to Talk channel at a time. A five-line intercom
/// therefore has to nominate one line as the one that survives the screen going
/// dark — and has to say which, because an operator who believes all five are
/// reachable from a pocket is worse off than one who knows only the director's
/// line is.
enum BackgroundTalkLine {
    /// The part of a channel this decision needs. Narrow on purpose: the rule
    /// stays measurable without assembling a whole configuration around it.
    struct Candidate: Equatable, Sendable {
        let id: UUID
        let name: String
        let role: ChannelRole
        let canTalk: Bool
        let isListening: Bool
        let isPrivate: Bool
    }

    /// Why this line was nominated. Carried so the interface can explain itself
    /// instead of showing a name with no reason next to it.
    enum Basis: Equatable, Sendable {
        case operatorChoice
        case directorsLine
        case listenedLine
        case onlyTalkableLine
        case firstTalkableLine
        /// No line at all — distinguished from `noTalkableLine` because the two
        /// call for different words on screen.
        case noChannels
        case noTalkableLine
    }

    struct Selection: Equatable, Sendable {
        /// Nil exactly when `basis` is `noChannels` or `noTalkableLine`.
        let channelID: UUID?
        let basis: Basis
        /// Set when the operator's explicit pick could not be honoured, naming
        /// it if we still know the name.
        ///
        /// This must reach the screen. A background line that moves silently is
        /// how an operator presses the button expecting the director and is
        /// heard by the whole programme feed instead — the failure is not that
        /// nothing happens, it is that the wrong thing does.
        let lostOperatorChoice: LostChoice?
    }

    enum LostChoice: Equatable, Sendable {
        /// The channel is gone from the configuration entirely.
        case removed
        /// Still there, but the server no longer grants talk on it.
        case noLongerTalkable(name: String)
        /// Still there, but it is an ephemeral private call, which we refuse to
        /// hold in the background (see `isEligible`).
        case becamePrivate(name: String)
    }

    /// A line we would be willing to hold in the background.
    ///
    /// Two exclusions, both deliberate:
    /// - **Cannot talk.** Offering a system button that transmits nothing is
    ///   worse than offering none: the operator finds out at the moment they
    ///   needed it.
    /// - **Private (ephemeral) call.** It disappears when the other party hangs
    ///   up. A background line that vanishes mid-shift, with the system UI
    ///   quietly folding away, is the same silent degradation in slow motion.
    static func isEligible(_ candidate: Candidate) -> Bool {
        candidate.canTalk && !candidate.isPrivate
    }

    /// Nominates the background line.
    ///
    /// Order: the operator's own pick, then the director's line, then a line
    /// they are already listening to, then whatever is left. The director comes
    /// before "whatever is listened" because that is the line a production
    /// cannot afford to miss — and it is the one an operator would choose if
    /// asked, so defaulting to it makes the common case need no configuration.
    static func select(from candidates: [Candidate], operatorChoice: UUID?) -> Selection {
        let eligible = candidates.filter(isEligible)

        // Worked out before the early returns: an operator whose pick fell away
        // has to be told even when there is nothing to fall back to.
        let lost = lostChoice(operatorChoice: operatorChoice, candidates: candidates, eligible: eligible)

        guard !candidates.isEmpty else {
            return Selection(channelID: nil, basis: .noChannels, lostOperatorChoice: lost)
        }
        guard !eligible.isEmpty else {
            return Selection(channelID: nil, basis: .noTalkableLine, lostOperatorChoice: lost)
        }

        if let operatorChoice, let honoured = eligible.first(where: { $0.id == operatorChoice }) {
            return Selection(channelID: honoured.id, basis: .operatorChoice, lostOperatorChoice: nil)
        }

        if eligible.count == 1 {
            return Selection(channelID: eligible[0].id, basis: .onlyTalkableLine, lostOperatorChoice: lost)
        }
        if let director = eligible.first(where: { $0.role == .priority }) {
            return Selection(channelID: director.id, basis: .directorsLine, lostOperatorChoice: lost)
        }
        if let listened = eligible.first(where: \.isListening) {
            return Selection(channelID: listened.id, basis: .listenedLine, lostOperatorChoice: lost)
        }
        return Selection(channelID: eligible[0].id, basis: .firstTalkableLine, lostOperatorChoice: lost)
    }

    private static func lostChoice(
        operatorChoice: UUID?,
        candidates: [Candidate],
        eligible: [Candidate]
    ) -> LostChoice? {
        guard let operatorChoice else { return nil }
        guard !eligible.contains(where: { $0.id == operatorChoice }) else { return nil }
        guard let stale = candidates.first(where: { $0.id == operatorChoice }) else { return .removed }
        // Order matters: a private line the server also revoked talk on is
        // reported as revoked, because that is the fact the operator can act on.
        if !stale.canTalk { return .noLongerTalkable(name: stale.name) }
        return .becamePrivate(name: stale.name)
    }

    /// Which microphones must close as the app leaves the foreground.
    ///
    /// Everything closes — except a background line the *system* is holding
    /// open. The rule the app has always followed is "a latched microphone must
    /// not stay open behind another app, because the button that would close it
    /// is no longer on screen." Under Push to Talk that premise is false: the
    /// system's own control is on screen, over the lock screen, with a stop
    /// button on it. So the exemption is not a loosening of the fail-safe, it is
    /// the same fail-safe applied to a case where the visible stop exists.
    ///
    /// `isSystemTransmitting` is what makes this safe. A background line that is
    /// open because the *app* opened it gets closed like any other: nothing is
    /// on screen to stop it.
    static func channelsToSilenceOnLeavingForeground(
        talking: [UUID],
        backgroundLine: UUID?,
        isSystemTransmitting: Bool
    ) -> [UUID] {
        guard isSystemTransmitting, let backgroundLine else { return talking }
        return talking.filter { $0 != backgroundLine }
    }
}
