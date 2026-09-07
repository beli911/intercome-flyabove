import SwiftUI

/// One party line.
///
/// The row is a strip of equipment: a colour bar to identify the line at a
/// glance, the name, and two controls sized to be hit with a thumb. When the
/// microphone is open the whole row is outlined in red — the operator has to be
/// able to see they are live from across a dark gallery.
struct ChannelRow: View {
    let channel: IntercomChannel
    let isEnabled: Bool
    let talkMode: TalkMode
    let onToggleListening: () -> Void
    /// Called with the desired Talk state. Momentary sends true on press and
    /// false on release; latch sends the toggled value on press only.
    let onTalkChanged: (Bool) -> Void
    let onOpenSettings: () -> Void

    @State private var isPressed = false

    private var isLive: Bool { channel.isTalking }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(channelHex: channel.colorHex))
                .frame(width: DS.channelBarWidth)

            details

            listenControl
            talkControl
        }
        .frame(minHeight: DS.controlHeight)
        .background(DS.surface)
        .overlay {
            Rectangle()
                .stroke(isLive ? DS.live : DS.line, lineWidth: DS.hairline)
        }
        .animation(.linear(duration: 0.12), value: isLive)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(channel.name)
                    .font(DS.display(17, .bold))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)

                if channel.isPrivate {
                    MonoLabel(text: "PRIVÁT", size: 9, weight: .bold, color: DS.accentText)
                }
                if channel.isRemoteSpeaking {
                    SpeakingIndicator()
                }
            }

            Text(meta.uppercased())
                .font(DS.mono(10, .regular))
                .tracking(0.4)
                .foregroundStyle(DS.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenSettings)
    }

    private var meta: String {
        if channel.isPrivate {
            var parts = ["privát vonal"]
            if channel.participantCount > 0 { parts.append("\(channel.participantCount) fő") }
            return parts.joined(separator: " · ")
        }
        var parts = [channel.detail]
        if channel.participantCount > 0 { parts.append("\(channel.participantCount) fő") }
        if !channel.canTalk { parts.append("csak hallgatás") }
        return parts.joined(separator: " · ")
    }

    private var listenControl: some View {
        Button(action: onToggleListening) {
            MonoLabel(
                text: channel.isListening ? "LISTEN" : "MUTE",
                size: 11,
                color: channel.isListening ? DS.ink : DS.live
            )
            .frame(width: DS.listenWidth)
            .frame(maxHeight: .infinity)
            .background(channel.isListening ? DS.fillSoft : .clear)
            .overlay(alignment: .leading) { Rectangle().frame(width: DS.hairline).foregroundStyle(DS.line) }
            .overlay(alignment: .trailing) { Rectangle().frame(width: DS.hairline).foregroundStyle(DS.line) }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || !channel.canListen)
        .opacity(channel.canListen ? 1 : 0.35)
        .accessibilityLabel("Hallgatás: \(channel.name)")
        .accessibilityValue(channel.isListening ? "bekapcsolva" : "némítva")
    }

    @ViewBuilder
    private var talkControl: some View {
        if channel.canTalk {
            MonoLabel(
                text: isLive ? "ÉLŐ" : "TALK",
                size: 15,
                weight: .bold,
                color: isLive ? .white : DS.ink
            )
            .frame(width: DS.talkWidth)
            .frame(maxHeight: .infinity)
            .background(isLive ? DS.live : DS.fill)
            .contentShape(Rectangle())
            .gesture(talkGesture)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Beszéd: \(channel.name)")
            .accessibilityValue(isLive ? "élő" : "kikapcsolva")
        } else {
            // A line this operator may only listen to still shows the control
            // slot, so the rows stay aligned and the restriction is visible
            // rather than implied by a missing button.
            MonoLabel(text: "—", size: 15, weight: .bold, color: DS.ink3)
                .frame(width: DS.talkWidth)
                .frame(maxHeight: .infinity)
                .accessibilityLabel("\(channel.name): nincs beszédjogosultság")
        }
    }

    /// The gesture reports intent from its own press state, never from the
    /// rendered `isTalking`: that value only changes after the transport call
    /// completes, so reading it here would misfire on a fast drag.
    private var talkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard isEnabled, !isPressed else { return }
                isPressed = true
                switch talkMode {
                case .momentary: onTalkChanged(true)
                case .latch: onTalkChanged(!channel.isTalking)
                }
            }
            .onEnded { _ in
                guard isPressed else { return }
                isPressed = false
                // Latch stays open until the next tap; only momentary closes on
                // release.
                if talkMode == .momentary { onTalkChanged(false) }
            }
    }
}

/// Someone else is speaking on this line.
private struct SpeakingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { index in
                Capsule()
                    .fill(DS.ok)
                    .frame(width: 2, height: isAnimating ? 11 : 4)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever()
                            .delay(Double(index) * 0.12),
                        value: isAnimating
                    )
            }
        }
        .frame(height: 12)
        .onAppear { isAnimating = true }
        .accessibilityLabel("Valaki beszél")
    }
}
