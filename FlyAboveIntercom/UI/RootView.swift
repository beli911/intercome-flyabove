import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: IntercomViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        ConnectionHeader(viewModel: viewModel)

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
            .disabled(viewModel.connectionState == .connecting)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .gray
        case .failed: .red
        }
    }
}
