import SwiftUI

struct ChannelCard: View {
    let channel: IntercomChannel
    let isEnabled: Bool
    let onToggleListening: () -> Void
    let onTalkChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Circle()
                    .fill(Color(hex: channel.colorHex))
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.headline)
                    Text(channel.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label("\(channel.participantCount)", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(action: onToggleListening) {
                    Label(
                        channel.isListening ? "LISTEN" : "NÉMÍTVA",
                        systemImage: channel.isListening ? "ear.fill" : "ear.badge.xmark"
                    )
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .tint(channel.isListening ? Color(hex: channel.colorHex) : .secondary)

                TalkButton(
                    isTalking: channel.isTalking,
                    tint: Color(hex: channel.colorHex),
                    onChanged: onTalkChanged
                )
            }
            .disabled(!isEnabled)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(channel.isTalking ? Color.red : .clear, lineWidth: 2)
        }
        .animation(.easeOut(duration: 0.15), value: channel.isTalking)
    }
}

private struct TalkButton: View {
    let isTalking: Bool
    let tint: Color
    let onChanged: (Bool) -> Void

    var body: some View {
        Text(isTalking ? "BESZÉLSZ" : "TALK")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(isTalking ? Color.red : tint, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isTalking { onChanged(true) }
                    }
                    .onEnded { _ in onChanged(false) }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Beszéd: \(isTalking ? "bekapcsolva" : "kikapcsolva")")
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x5B8CFF
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
