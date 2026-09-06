import Combine
import Foundation

@MainActor
final class IntercomViewModel: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var configuration: IntercomConfiguration
    @Published var errorMessage: String?

    private let transport: any IntercomTransport
    private let audioSession: any AudioSessionControlling

    init(
        configuration: IntercomConfiguration = .demo,
        transport: any IntercomTransport,
        audioSession: any AudioSessionControlling
    ) {
        self.configuration = configuration
        self.transport = transport
        self.audioSession = audioSession
    }

    var isConnected: Bool { connectionState == .connected }
    var activeTalkChannelCount: Int { configuration.channels.filter(\.isTalking).count }

    func connect() async {
        guard connectionState != .connecting else { return }
        connectionState = .connecting
        errorMessage = nil

        guard await audioSession.requestMicrophonePermission() else {
            fail(with: AudioSessionError.microphonePermissionDenied)
            return
        }

        do {
            try await audioSession.activate()
            try await transport.connect(configuration: configuration)
            connectionState = .connected
        } catch {
            await audioSession.deactivate()
            fail(with: error)
        }
    }

    func disconnect() async {
        stopTalkingLocally()
        await transport.disconnect()
        await audioSession.deactivate()
        connectionState = .disconnected
    }

    func toggleListening(channelID: UUID) async {
        guard let index = channelIndex(for: channelID), isConnected else { return }
        let previous = configuration.channels[index].isListening
        configuration.channels[index].isListening.toggle()

        do {
            try await transport.setListening(!previous, channelID: channelID)
        } catch {
            configuration.channels[index].isListening = previous
            fail(with: error, preservingConnection: true)
        }
    }

    func setTalking(_ enabled: Bool, channelID: UUID) async {
        guard let index = channelIndex(for: channelID), isConnected else { return }
        let previous = configuration.channels[index].isTalking
        configuration.channels[index].isTalking = enabled

        do {
            try await transport.setTalking(enabled, channelID: channelID)
        } catch {
            configuration.channels[index].isTalking = previous
            fail(with: error, preservingConnection: true)
        }
    }

    private func channelIndex(for id: UUID) -> Int? {
        configuration.channels.firstIndex(where: { $0.id == id })
    }

    private func stopTalkingLocally() {
        for index in configuration.channels.indices {
            configuration.channels[index].isTalking = false
        }
    }

    private func fail(with error: Error, preservingConnection: Bool = false) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        if !preservingConnection {
            connectionState = .failed(message: message)
        }
    }
}
