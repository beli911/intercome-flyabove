import AVFAudio
import Foundation

protocol AudioSessionControlling: Sendable {
    func requestMicrophonePermission() async -> Bool
    func activate() async throws
    func deactivate() async
}

enum AudioSessionError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        "A mikrofon használata nincs engedélyezve. Engedélyezd a Beállításokban."
    }
}

final class AudioSessionController: AudioSessionControlling, @unchecked Sendable {
    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

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
}
