import AVFAudio
import Foundation
import PushToTalk
import UIKit

/// What the system did to the background line, reduced to the cases an intercom
/// cares about. Free of `PushToTalk` types on purpose, so the view model and its
/// tests stay independent of a framework that cannot run in a simulator.
enum BackgroundTalkEvent: Sendable, Equatable {
    case joined(channelID: UUID, wasRestored: Bool)
    /// The line is no longer held. `wasOurDecision` separates "we let it go"
    /// from "the system or the user took it" — the second has to reach the
    /// screen, because the operator's pocket just went quiet.
    case left(channelID: UUID, wasOurDecision: Bool)
    case beganTransmitting(channelID: UUID, fromAccessoryButton: Bool)
    case endedTransmitting(channelID: UUID)
    case audioSessionActivated
    case audioSessionDeactivated
    /// Something the operator has to know about, already in words they can read.
    /// A background line that quietly does not work is the failure this whole
    /// feature exists to prevent, so every refusal comes out here.
    case unavailable(reason: String)
    /// This build cannot do Push to Talk at all — most often the entitlement is
    /// not on the provisioning profile. Kept apart from `unavailable` on
    /// purpose: a capability the operator was never given is not a malfunction,
    /// and warning about it on every launch would teach them to ignore the
    /// warnings that do matter.
    case unsupported(reason: String)
}

@MainActor
protocol BackgroundTalkControlling: AnyObject {
    /// False when the system would not give us a channel manager at all — most
    /// often a build without the Push to Talk entitlement.
    var isSupported: Bool { get }
    func prepare() async
    /// Hands one line to the system. Idempotent for the line already held.
    func join(channelID: UUID, name: String) async
    func leave() async
    /// Drives the system's own transmit state from an in-app button, so a line
    /// the operator opened on screen is the same line the system is holding.
    func setTransmitting(_ transmitting: Bool)
    func events() -> AsyncStream<BackgroundTalkEvent>
}

/// Holds one line open through the system's Push to Talk service, so the
/// operator can still talk with the phone locked or another app in front.
///
/// Nothing here decides *which* line: that is `BackgroundTalkLine`, which is a
/// pure function and therefore measurable. This file is the part that cannot be
/// measured without an entitlement and a physical device, and it is kept as thin
/// as that fact deserves.
@MainActor
final class PushToTalkService: NSObject, BackgroundTalkControlling {
    private var manager: PTChannelManager?
    private var heldChannel: UUID?
    /// Set while we are the ones leaving, so the delegate can tell our own
    /// `leave()` apart from the system or the user taking the line away.
    private var isLeavingOnPurpose = false
    private var continuations: [UUID: AsyncStream<BackgroundTalkEvent>.Continuation] = [:]

    private(set) var isSupported = false

    func events() -> AsyncStream<BackgroundTalkEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func prepare() async {
        guard manager == nil else { return }
        do {
            manager = try await PTChannelManager.channelManager(
                delegate: self,
                restorationDelegate: self
            )
            isSupported = true
        } catch {
            isSupported = false
            // Named, not swallowed. Without the entitlement this is exactly
            // where an operator would otherwise be left believing the pocket
            // works.
            emit(.unsupported(reason: "A háttér-adás ebben a buildben nem érhető el: \(error.localizedDescription)"))
        }
    }

    func join(channelID: UUID, name: String) async {
        if manager == nil { await prepare() }
        guard let manager else { return }
        guard heldChannel != channelID else { return }

        if let heldChannel {
            isLeavingOnPurpose = true
            manager.leaveChannel(channelUUID: heldChannel)
        }
        heldChannel = channelID
        manager.requestJoinChannel(
            channelUUID: channelID,
            descriptor: PTChannelDescriptor(name: name, image: nil)
        )
    }

    func leave() async {
        guard let manager, let heldChannel else { return }
        isLeavingOnPurpose = true
        manager.leaveChannel(channelUUID: heldChannel)
        self.heldChannel = nil
    }

    func setTransmitting(_ transmitting: Bool) {
        guard let manager, let heldChannel else { return }
        if transmitting {
            manager.requestBeginTransmitting(channelUUID: heldChannel)
        } else {
            manager.stopTransmitting(channelUUID: heldChannel)
        }
    }

    private func emit(_ event: BackgroundTalkEvent) {
        // Szándékosan `print`, és szándékosan NEM `#if DEBUG`.
        //
        // A rendszer-keretrendszerek és a LiveKit az egységesített naplóba
        // írnak, ami egy csatlakoztatott telefonról nem streamelhető — ezért a
        // `--console` figyelő gyakorlatilag vak volt. Ez a sor a stdout-ra megy,
        // tehát látszik. És azért marad Release-ben is, mert egy diagnosztika,
        // ami pont a terepi buildből tűnik el, akkor hiányzik, amikor kell.
        print("[Flycom][PTT] \(event)")
        for continuation in continuations.values { continuation.yield(event) }
    }
}

// MARK: - PTChannelManagerDelegate

extension PushToTalkService: PTChannelManagerDelegate {
    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didJoinChannel channelUUID: UUID,
        reason: PTChannelJoinReason
    ) {
        let restored = reason == .channelRestoration
        Task { @MainActor in
            self.heldChannel = channelUUID
            // Half duplex: an intercom line where two people talk over each
            // other is worse than one that makes them take turns, and it is
            // what the hardware buttons expect.
            channelManager.setTransmissionMode(.halfDuplex, channelUUID: channelUUID, completionHandler: nil)
            // The reason this framework is worth the entitlement: a wired or
            // Bluetooth PTT button reaches the app with the screen off.
            channelManager.setAccessoryButtonEventsEnabled(true, channelUUID: channelUUID, completionHandler: nil)
            self.emit(.joined(channelID: channelUUID, wasRestored: restored))
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didLeaveChannel channelUUID: UUID,
        reason: PTChannelLeaveReason
    ) {
        Task { @MainActor in
            let ours = self.isLeavingOnPurpose
            self.isLeavingOnPurpose = false
            if self.heldChannel == channelUUID { self.heldChannel = nil }
            self.emit(.left(channelID: channelUUID, wasOurDecision: ours))
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didBeginTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        let fromButton = source == .handsfreeButton
        Task { @MainActor in
            self.emit(.beganTransmitting(channelID: channelUUID, fromAccessoryButton: fromButton))
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didEndTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        Task { @MainActor in
            self.emit(.endedTransmitting(channelID: channelUUID))
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didActivate audioSession: AVAudioSession
    ) {
        Task { @MainActor in self.emit(.audioSessionActivated) }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        didDeactivate audioSession: AVAudioSession
    ) {
        Task { @MainActor in self.emit(.audioSessionDeactivated) }
    }

    // MARK: Failures — every one of these reaches the operator

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        failedToJoinChannel channelUUID: UUID,
        error: any Error
    ) {
        Task { @MainActor in
            if self.heldChannel == channelUUID { self.heldChannel = nil }
            self.emit(.unavailable(reason: "A háttérvonal nem foglalható le: \(error.localizedDescription)"))
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        failedToLeaveChannel channelUUID: UUID,
        error: any Error
    ) {
        Task { @MainActor in
            self.emit(.unavailable(reason: "A háttérvonal nem engedhető el: \(error.localizedDescription)"))
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        failedToBeginTransmittingInChannel channelUUID: UUID,
        error: any Error
    ) {
        Task { @MainActor in
            self.emit(.unavailable(reason: "A háttér-adás nem indult el: \(error.localizedDescription)"))
        }
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        failedToStopTransmittingInChannel channelUUID: UUID,
        error: any Error
    ) {
        Task { @MainActor in
            // The dangerous direction: we do not know whether the line is still
            // open, so it is said out loud rather than assumed closed.
            self.emit(.unavailable(reason: "A háttér-adás nem állt le, a vonal nyitva maradhatott."))
        }
    }

    // MARK: Push — unused, and deliberately so

    /// We never send Push to Talk pushes: this build only ever *talks* from the
    /// background, and incoming audio arrives over the room we are already
    /// joined to. Answering "leave" is the honest reply to a push we did not
    /// send, rather than pretending a participant is speaking.
    nonisolated func incomingPushResult(
        channelManager: PTChannelManager,
        channelUUID: UUID,
        pushPayload: [String: Any]
    ) -> PTPushResult {
        .leaveChannel
    }

    nonisolated func channelManager(
        _ channelManager: PTChannelManager,
        receivedEphemeralPushToken pushToken: Data
    ) {
        // Nothing to register: see `incomingPushResult`.
    }
}

// MARK: - PTChannelRestorationDelegate

extension PushToTalkService: PTChannelRestorationDelegate {
    /// The system is offering to restore a line after a relaunch. We refuse: the
    /// channel the app held yesterday may no longer exist, may have had talk
    /// revoked, or may belong to a production that has wrapped — and a restored
    /// line the operator never chose is the same "wrong room" failure the
    /// selection rule exists to prevent. The line is re-joined once the app has
    /// connected and re-read its permissions.
    nonisolated func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        PTChannelDescriptor(name: "Flycom", image: nil)
    }
}
