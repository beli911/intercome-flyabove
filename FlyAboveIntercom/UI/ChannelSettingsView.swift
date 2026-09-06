import SwiftUI

/// Per-line settings, reachable by tapping a channel's name.
///
/// Only controls that actually do something are shown. Per-channel volume, IFB
/// ducking and priority are in the proposal but belong to later milestones, and
/// a dead switch on a live intercom is worse than a missing one — they are
/// named here as pending instead of faked.
struct ChannelSettingsView: View {
    let channel: IntercomChannel
    @ObservedObject var viewModel: IntercomViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            DS.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        volumeSection
                        talkModeSection
                        permissionSection
                        pendingSection
                    }
                    .padding(14)
                }

                if channel.canListen {
                    BlockButton(
                        title: channel.isListening ? "CSATORNA NÉMÍTÁSA" : "CSATORNA VISSZAKAPCSOLÁSA",
                        isEnabled: viewModel.isConnected
                    ) {
                        Task {
                            await viewModel.toggleListening(channelID: channel.id)
                            dismiss()
                        }
                    }
                    .padding(14)
                }
            }
        }
        .preferredColorScheme(viewModel.theme.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color(channelHex: channel.colorHex))
                .frame(width: DS.channelBarWidth, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(DS.display(20, .bold))
                    .foregroundStyle(DS.ink)
                MonoLabel(
                    text: "\(channel.detail) · \(channel.participantCount) FŐ",
                    size: 11,
                    weight: .regular,
                    color: DS.ink3
                )
            }

            Spacer()

            Button { dismiss() } label: {
                MonoLabel(text: "KÉSZ", size: 11, weight: .bold, color: DS.ink)
                    .frame(width: DS.iconSize + 8, height: DS.iconSize)
                    .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .padding(.top, 8)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: DS.hairline).foregroundStyle(DS.line)
        }
    }

    /// Per-channel level, in the decibels an audio operator thinks in rather
    /// than the linear gain LiveKit takes.
    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MonoLabel(text: "HANGERŐ", size: 11, color: DS.ink2)
                Spacer()
                // Not a MonoLabel: "dB" is a unit, and uppercasing it to "DB"
                // is wrong in a way an audio operator notices.
                Text(ChannelVolume.label(forGain: channel.volume))
                    .font(DS.mono(12, .bold))
                    .tracking(DS.monoTracking)
                    .foregroundStyle(channel.volume == 0 ? DS.live : DS.ink)
            }

            Slider(
                value: Binding(
                    get: { ChannelVolume.sliderPosition(forGain: channel.volume) },
                    set: { position in
                        Task {
                            await viewModel.setVolume(
                                ChannelVolume.gain(forSliderPosition: position),
                                channelID: channel.id
                            )
                        }
                    }
                ),
                in: 0 ... 1
            )
            .tint(DS.accentText)
            .disabled(!channel.canListen)

            HStack {
                ForEach(ChannelVolume.ticks, id: \.self) { tick in
                    MonoLabel(text: tick, size: 10, weight: .regular, color: DS.ink3)
                    if tick != ChannelVolume.ticks.last { Spacer() }
                }
            }
        }
        .padding(12)
        .background(DS.surface)
        .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
    }

    private var talkModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: "TALK MÓD", size: 11, color: DS.ink2)

            ForEach(TalkMode.allCases) { mode in
                Button { viewModel.talkMode = mode } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Rectangle()
                            .fill(viewModel.talkMode == mode ? DS.accent : .clear)
                            .frame(width: 14, height: 14)
                            .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            MonoLabel(text: mode.title, size: 12, weight: .bold, color: DS.ink)
                            Text(mode.explanation)
                                .font(DS.display(12, .regular))
                                .foregroundStyle(DS.ink3)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.surface)
                    .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
                }
                .buttonStyle(.plain)
            }

            Text("A beállítás minden vonalra érvényes.")
                .font(DS.display(12, .regular))
                .foregroundStyle(DS.ink3)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: "JOGOSULTSÁG", size: 11, color: DS.ink2)

            HStack(spacing: 8) {
                PermissionPill(title: "TALK", isGranted: channel.canTalk)
                PermissionPill(title: "LISTEN", isGranted: channel.canListen)
            }

            Text("A szerver minden kérésnél újraellenőrzi. A kliens által küldött jog nem mérvadó.")
                .font(DS.display(12, .regular))
                .foregroundStyle(DS.ink3)
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: "KÉSŐBBI MÉRFÖLDKŐ", size: 11, color: DS.ink2)

            VStack(alignment: .leading, spacing: 8) {
                PendingRow(title: "IFB ducking", milestone: "M3")
                PendingRow(title: "Prioritás jelzés", milestone: "M3")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.surface)
            .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
        }
    }
}

private struct PermissionPill: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        MonoLabel(
            text: title,
            size: 12,
            weight: .bold,
            color: isGranted ? DS.onAccent : DS.ink3
        )
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(isGranted ? DS.ok : .clear)
        .overlay {
            if !isGranted { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
        }
        .accessibilityLabel("\(title): \(isGranted ? "engedélyezve" : "nincs jogosultság")")
    }
}

private struct PendingRow: View {
    let title: String
    let milestone: String

    var body: some View {
        HStack {
            Text(title)
                .font(DS.display(13, .regular))
                .foregroundStyle(DS.ink3)
            Spacer()
            MonoLabel(text: milestone, size: 10, weight: .bold, color: DS.ink3)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
        }
    }
}
