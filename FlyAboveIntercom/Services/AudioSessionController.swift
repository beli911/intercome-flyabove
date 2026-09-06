import AVFAudio
import Foundation

/// What the system did to our audio, reduced to the cases an intercom cares
/// about. Deliberately free of `AVFoundation` types so the view model and its
/// tests stay independent of the framework.
enum AudioSessionEvent: Sendable {
    /// A phone call, Siri or another app took the session. The microphone is
    /// gone until further notice.
    case interruptionBegan
    /// `shouldResume` is the system's hint that we may reactivate immediately.
    case interruptionEnded(shouldResume: Bool)
    /// A headset or Bluetooth device came or went. `outputName` is the route in
    /// effect after the change.
    case routeChanged(reason: AudioRouteChangeReason, outputName: String?)
    /// The media daemon restarted; every session and track must be rebuilt.
    case mediaServicesWereReset
}

enum AudioRouteChangeReason: Sendable, Equatable {
    case deviceConnected
    case deviceDisconnected
    case categoryChanged
    case other
}

protocol AudioSessionControlling: Sendable {
    func requestMicrophonePermission() async -> Bool
    func activate() async throws
    func deactivate() async
    func events() async -> AsyncStream<AudioSessionEvent>
    func currentOutputName() async -> String?
}

enum AudioSessionError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        "A mikrofon használata nincs engedélyezve. Engedélyezd a Beállításokban."
    }
}

final class AudioSessionController: AudioSessionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AudioSessionEvent>.Continuation] = [:]
    private var observers: [any NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        let session = AVAudioSession.sharedInstance()

        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }

            switch type {
            case .began:
                self.emit(.interruptionBegan)
            case .ended:
                let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                self.emit(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                break
            }
        })

        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            self.emit(.routeChanged(
                reason: AudioRouteChangeReason(reason),
                outputName: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
            ))
        })

        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.emit(.mediaServicesWereReset)
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        lock.withLock {
            for continuation in continuations.values { continuation.finish() }
            continuations.removeAll()
        }
    }

    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Configures the session for two-way low-latency voice.
    ///
    /// LiveKit reconfigures the session again when it publishes or subscribes to
    /// a track; these values are the ones that survive and matter before that
    /// happens (and are the whole story for the preview transport).
    func activate() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    func deactivate() async {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func events() async -> AsyncStream<AudioSessionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func currentOutputName() async -> String? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
    }

    private func emit(_ event: AudioSessionEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(event) }
    }
}

private extension AudioRouteChangeReason {
    init(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .newDeviceAvailable: self = .deviceConnected
        case .oldDeviceUnavailable: self = .deviceDisconnected
        case .categoryChange: self = .categoryChanged
        default: self = .other
        }
    }
}
