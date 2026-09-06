import SwiftUI

/// The intercom itself: a header that never hides the link state, one strip per
/// line, and the two panel-wide keys at the bottom where a thumb rests.
struct RootView: View {
    @ObservedObject var viewModel: IntercomViewModel
    var isDemoMode: Bool = false
    var onSignOut: (() async -> Void)?

    @State private var settingsChannelID: UUID?
    @State private var selectedTab: Tab = .lines

    enum Tab: String, CaseIterable, Identifiable {
        case lines = "VONALAK"
        case crew = "CREW"
        case admin = "ADMIN"
        case profile = "PROFIL"

        var id: String { rawValue }
        /// Crew and admin are M2/M3; they are shown so the layout is honest
        /// about where they will live, but they do not pretend to work.
        var isAvailable: Bool { self == .lines || self == .profile }
    }

    var body: some View {
        ZStack {
            DS.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(DS.line)

                switch selectedTab {
                case .lines: linesTab
                case .profile:
                    ProfileView(viewModel: viewModel, onSignOut: onSignOut)
                case .crew, .admin:
                    ComingSoonPane(tab: selectedTab)
                }

                Divider().overlay(DS.line)
                tabBar
            }
        }
        .preferredColorScheme(viewModel.theme.colorScheme)
        .alert("Hiba", isPresented: errorBinding) {
            Button("Rendben", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Ismeretlen hiba")
        }
        .sheet(item: $settingsChannelID) { channelID in
            if let channel = viewModel.configuration.channels.first(where: { $0.id == channelID }) {
                ChannelSettingsView(channel: channel, viewModel: viewModel)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.configuration.displayName)
                    .font(DS.display(15, .semibold))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    MonoLabel(text: statusLine, size: 11, weight: .regular, color: DS.ink2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            talkModeChip

            Button {
                Task {
                    if viewModel.isConnected {
                        await viewModel.disconnect()
                    } else {
                        await viewModel.connect()
                    }
                }
            } label: {
                MonoLabel(
                    text: viewModel.isConnected ? "BONT" : "BE",
                    size: 11,
                    weight: .bold,
                    color: viewModel.isConnected ? DS.live : DS.onAccent
                )
                .frame(width: DS.iconSize + 14, height: DS.iconSize)
                .background(viewModel.isConnected ? Color.clear : DS.accent)
                .overlay {
                    if viewModel.isConnected {
                        Rectangle().stroke(DS.live, lineWidth: DS.hairline)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.connectionState == .connecting)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// The status line doubles as the developer readout: in an intercom the
    /// round-trip time is operational information, not a debug detail.
    private var statusLine: String {
        var parts = [viewModel.connectionState.title.uppercased()]
        if viewModel.isDeveloperModeEnabled, let statistics = viewModel.statistics {
            parts.append(statistics.roundTripDescription)
        }
        if let route = viewModel.audioRouteName {
            parts.append(route.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .connected: DS.ok
        case .connecting, .reconnecting: DS.accent
        case .disconnected: DS.ink3
        case .failed: DS.live
        }
    }

    private var talkModeChip: some View {
        Button {
            viewModel.talkMode = viewModel.talkMode == .momentary ? .latch : .momentary
        } label: {
            MonoLabel(
                text: viewModel.talkMode == .latch ? "LATCH" : "MOM",
                size: 11,
                weight: .bold,
                color: viewModel.talkMode == .latch ? DS.onAccent : DS.ink2
            )
            .padding(.horizontal, 10)
            .frame(height: DS.iconSize)
            .background(viewModel.talkMode == .latch ? DS.accent : .clear)
            .overlay {
                if viewModel.talkMode == .momentary {
                    Rectangle().stroke(DS.line, lineWidth: DS.hairline)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("PTT mód")
        .accessibilityValue(viewModel.talkMode.title)
    }

    // MARK: - Lines

    private var linesTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    if isDemoMode { DemoModeBanner() }
                    if viewModel.isMicrophoneGranted == false { MicrophoneDeniedBanner() }

                    ForEach(viewModel.configuration.channels) { channel in
                        ChannelRow(
                            channel: channel,
                            isEnabled: viewModel.isConnected,
                            talkMode: viewModel.talkMode,
                            onToggleListening: {
                                Task { await viewModel.toggleListening(channelID: channel.id) }
                            },
                            // Synchronous: the press/release order has to be
                            // recorded before any suspension point.
                            onTalkChanged: { isTalking in
                                viewModel.requestTalking(isTalking, channelID: channel.id)
                            },
                            onOpenSettings: { settingsChannelID = channel.id }
                        )
                    }

                    if !viewModel.isConnected {
                        Text("Kapcsolódj a vonalakhoz a BE gombbal.")
                            .font(DS.display(13, .regular))
                            .foregroundStyle(DS.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            transportBar
        }
    }

    private var transportBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.setListeningOnAllChannels(!viewModel.isListeningAnywhere) }
            } label: {
                MonoLabel(
                    text: viewModel.isListeningAnywhere ? "MUTE ALL" : "UNMUTE",
                    size: 16,
                    weight: .bold,
                    color: viewModel.isListeningAnywhere ? DS.ink : DS.live
                )
                .frame(maxWidth: .infinity)
                .frame(height: DS.controlHeight)
                .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
            }
            .buttonStyle(.plain)

            TalkAllButton(
                isLive: viewModel.isTalkingOnEveryChannel,
                talkMode: viewModel.talkMode,
                isEnabled: viewModel.isConnected && viewModel.canTalkOnAnyChannel,
                onChanged: { viewModel.requestTalkingOnAllChannels($0) }
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .disabled(!viewModel.isConnected)
        .opacity(viewModel.isConnected ? 1 : 0.4)
        .overlay(alignment: .top) {
            Rectangle().frame(height: DS.hairline).foregroundStyle(DS.line)
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                Button {
                    guard tab.isAvailable else { return }
                    selectedTab = tab
                } label: {
                    VStack(spacing: 6) {
                        Rectangle()
                            .fill(selectedTab == tab ? DS.accent : DS.surface2)
                            .frame(width: 18, height: 3)
                        MonoLabel(
                            text: tab.rawValue,
                            size: 11,
                            color: selectedTab == tab ? DS.accentText : DS.ink3
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DS.iconSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!tab.isAvailable)
                .opacity(tab.isAvailable ? 1 : 0.35)
            }
        }
        .padding(.bottom, 4)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

/// Talk-all is a transport key, not a channel control, so it lives here rather
/// than in `ChannelRow`.
private struct TalkAllButton: View {
    let isLive: Bool
    let talkMode: TalkMode
    let isEnabled: Bool
    let onChanged: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        MonoLabel(
            text: isLive ? "ÉLŐ MINDENHOL" : "TALK ALL",
            size: 16,
            weight: .bold,
            color: isLive ? .white : DS.onAccent
        )
        .frame(maxWidth: .infinity)
        .frame(height: DS.controlHeight)
        .background(isLive ? DS.live : DS.accent)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !isPressed else { return }
                    isPressed = true
                    onChanged(talkMode == .latch ? !isLive : true)
                }
                .onEnded { _ in
                    guard isPressed else { return }
                    isPressed = false
                    if talkMode == .momentary { onChanged(false) }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Beszéd minden vonalon")
        .accessibilityValue(isLive ? "élő" : "kikapcsolva")
    }
}

private struct DemoModeBanner: View {
    var body: some View {
        BannerStrip(
            text: "DEMÓ MÓD · NINCS SZERVER, A HANG NEM MEGY HÁLÓZATON",
            color: DS.accentText,
            rule: DS.accent
        )
    }
}

private struct MicrophoneDeniedBanner: View {
    var body: some View {
        BannerStrip(
            text: "MIKROFON LETILTVA · HALLGATNI TUDSZ, BESZÉLNI NEM",
            color: DS.live,
            rule: DS.live
        )
    }
}

private struct BannerStrip: View {
    let text: String
    /// Readable in both themes.
    let color: Color
    /// The identifying stripe, which may stay saturated because nothing is
    /// written on it.
    let rule: Color

    var body: some View {
        MonoLabel(text: text, size: 11, color: color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(rule.opacity(0.12))
            .overlay(alignment: .leading) {
                Rectangle().frame(width: 3).foregroundStyle(rule)
            }
    }
}

private struct ComingSoonPane: View {
    let tab: RootView.Tab

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            MonoLabel(text: tab.rawValue, size: 13, weight: .bold, color: DS.ink2)
            MonoLabel(
                text: tab == .crew ? "RÉSZTVEVŐLISTA — M2" : "ADMIN FELÜLET — M2",
                size: 11,
                weight: .regular,
                color: DS.ink3
            )
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
