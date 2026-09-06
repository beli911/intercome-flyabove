import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: IntercomViewModel
    var isDemoMode: Bool = false
    var onSignOut: (() async -> Void)?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        ConnectionHeader(viewModel: viewModel)

                        if isDemoMode {
                            DemoModeBanner()
                        }

                        ForEach(viewModel.configuration.channels) { channel in
                            ChannelCard(
                                channel: channel,
                                isEnabled: viewModel.isConnected,
                                onToggleListening: {
                                    Task { await viewModel.toggleListening(channelID: channel.id) }
                                },
                                onTalkChanged: { isTalking in
                                    Task { await viewModel.setTalking(isTalking, channelID: channel.id) }
                                }
                            )
                        }

                        if viewModel.isDeveloperModeEnabled {
                            DeveloperOverlay(
                                statistics: viewModel.statistics,
                                routeName: viewModel.audioRouteName
                            )
                        }

                        Text("A TALK gombot tartsd lenyomva beszéd közben. A mikrofon csak kapcsolódás után aktiválható.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    .padding()
                }
            }
            .navigationTitle("FlyAbove Intercom")
            .toolbar {
                if let onSignOut {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Kilépés") { Task { await onSignOut() } }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "waveform.badge.mic")
                        .foregroundStyle(viewModel.activeTalkChannelCount > 0 ? .red : .secondary)
                        .accessibilityLabel("Aktív beszédcsatornák: \(viewModel.activeTalkChannelCount)")
                }
            }
            .alert("Hiba", isPresented: errorBinding) {
                Button("Rendben", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "Ismeretlen hiba")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct ConnectionHeader: View {
    let viewModel: IntercomViewModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.connectionState.title)
                    .font(.headline)
                Text(viewModel.configuration.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(viewModel.isConnected ? "Bontás" : "Kapcsolódás") {
                Task {
                    if viewModel.isConnected {
                        await viewModel.disconnect()
                    } else {
                        await viewModel.connect()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isConnected ? .red : .blue)
            .disabled(viewModel.connectionState == .connecting || viewModel.connectionState == .reconnecting)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected: .gray
        case .failed: .red
        }
    }
}

private struct DemoModeBanner: View {
    var body: some View {
        Label(
            "Demó mód: nincs beállítva szerver, a hang nem megy hálózaton.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Debug-only connection quality readout, so a soak test can be judged from the
/// device instead of the console.
private struct DeveloperOverlay: View {
    let statistics: IntercomStatistics?
    let routeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fejlesztői adatok")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(statistics?.roundTripDescription ?? "RTT –")
                Text(bitrate("↑", statistics?.availableOutgoingBitrateKbps))
                Text(bitrate("↓", statistics?.availableIncomingBitrateKbps))
            }
            .font(.caption.monospacedDigit())

            Text("Kimenet: \(routeName ?? "ismeretlen")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func bitrate(_ prefix: String, _ value: Double?) -> String {
        guard let value else { return "\(prefix) –" }
        return "\(prefix) \(Int(value.rounded())) kbps"
    }
}
