import SwiftUI

/// Who is on the production, and who is talking right now.
///
/// The list merges two sources that neither one alone can answer: the roster
/// from the API, and presence from the realtime connection.
struct CrewView: View {
    @ObservedObject var viewModel: IntercomViewModel
    let roster: [CrewMember]
    /// Nil in demo mode, where there is nobody to call.
    var currentUserID: UUID?
    var onStartPrivateCall: ((CrewMember) async -> Void)?
    var isBusy = false

    private var members: [CrewMember] { viewModel.crew(roster: roster) }
    private var onlineCount: Int { members.filter(\.isOnline).count }

    var body: some View {
        Group {
            if roster.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        summary
                        ForEach(members) { member in
                            CrewRow(
                                member: member,
                                channelName: channelName,
                                privateLineName: privateLineName(for: member),
                                canCall: canCall(member),
                                isBusy: isBusy,
                                onCall: onStartPrivateCall.map { call in
                                    { Task { await call(member) } }
                                }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var summary: some View {
        MonoLabel(
            text: "\(onlineCount) AKTÍV · \(members.count - onlineCount) OFFLINE",
            size: 11,
            color: DS.ink3
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            MonoLabel(text: "NINCS RÉSZTVEVŐLISTA", size: 12, weight: .bold, color: DS.ink2)
            Text("A produkció névsora nem érhető el.")
                .font(DS.display(12, .regular))
                .foregroundStyle(DS.ink3)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func channelName(_ id: UUID) -> String {
        viewModel.configuration.channels.first { $0.id == id }?.name ?? "—"
    }

    /// A private line is named after the other person, so a channel whose name
    /// matches this member is the line we already have with them.
    private func privateLineName(for member: CrewMember) -> String? {
        viewModel.configuration.channels
            .first { $0.isPrivate && $0.name == member.displayName }?
            .name
    }

    private func canCall(_ member: CrewMember) -> Bool {
        guard onStartPrivateCall != nil, viewModel.isConnected else { return false }
        // Calling yourself is not a thing, and neither is calling somebody who
        // is not on the line to answer.
        return member.isOnline && member.id != currentUserID
    }
}

private struct CrewRow: View {
    let member: CrewMember
    let channelName: (UUID) -> String
    let privateLineName: String?
    let canCall: Bool
    let isBusy: Bool
    let onCall: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(member.isSpeaking ? DS.ok : (member.isOnline ? DS.surface2 : .clear))
                .frame(width: DS.channelBarWidth)

            MonoLabel(
                text: member.initials,
                size: 12,
                weight: .bold,
                color: member.isOnline ? DS.ink : DS.ink3
            )
            .frame(width: 42, height: 42)
            .background(member.isOnline ? DS.fill : .clear)
            .overlay {
                if !member.isOnline { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
            }
            .padding(.leading, 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(DS.display(15, .semibold))
                        .foregroundStyle(member.isOnline ? DS.ink : DS.ink3)
                        .lineLimit(1)
                    if member.isSpeaking {
                        MonoLabel(text: "BESZÉL", size: 10, weight: .bold, color: DS.ok)
                    }
                }
                MonoLabel(text: detail, size: 10, weight: .regular, color: DS.ink3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            if privateLineName != nil {
                MonoLabel(text: "PRIVÁT", size: 10, weight: .bold, color: DS.accentText)
                    .padding(.trailing, 12)
            } else if canCall, let onCall {
                Button(action: onCall) {
                    MonoLabel(text: "HÍVÁS", size: 10, weight: .bold, color: DS.ink)
                        .frame(width: 62)
                        .frame(maxHeight: .infinity)
                        .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel("Privát hívás: \(member.displayName)")
            } else {
                MonoLabel(
                    text: member.isOnline ? member.quality.title : "OFFLINE",
                    size: 10,
                    weight: .regular,
                    color: qualityColor
                )
                .padding(.trailing, 12)
            }
        }
        .frame(minHeight: 62)
        .background(DS.surface)
        .overlay {
            Rectangle().stroke(member.isSpeaking ? DS.ok : DS.line, lineWidth: DS.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.displayName), \(member.role), \(member.isOnline ? "online" : "offline")")
    }

    private var detail: String {
        var parts = [member.role]
        if member.isOnline, !member.activeChannelIDs.isEmpty {
            parts.append(member.activeChannelIDs.map(channelName).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private var qualityColor: Color {
        guard member.isOnline else { return DS.ink3 }
        switch member.quality {
        case .lost, .poor: return DS.live
        case .good, .excellent: return DS.ink3
        case .unknown: return DS.ink3
        }
    }
}
