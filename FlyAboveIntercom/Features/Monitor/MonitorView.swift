import SwiftUI

/// Connection quality and what has happened this session.
///
/// "It dropped out once around the second half" is not something anyone can act
/// on. This screen answers the two questions that follow an incident: how the
/// link is doing right now, and what the app already noticed.
struct MonitorView: View {
    @ObservedObject var viewModel: IntercomViewModel
    @ObservedObject var events: EventLog
    let roster: [CrewMember]

    private var members: [CrewMember] { viewModel.crew(roster: roster) }

    /// Only the ones actually reachable, ordered worst first — a list of
    /// healthy links is not what anybody opens this screen for.
    private var worstLinks: [CrewMember] {
        members
            .filter { $0.isOnline && $0.quality != .unknown }
            .sorted { $0.quality < $1.quality }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                figures
                if !worstLinks.isEmpty { links }
                log
            }
            .padding(14)
        }
    }

    private var figures: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: "KAPCSOLAT", size: 11, color: DS.ink2)

            HStack(spacing: 8) {
                Figure(
                    title: "RTT",
                    value: viewModel.statistics?.roundTripTimeMilliseconds.map { "\(Int($0.rounded()))" } ?? "–",
                    unit: "ms",
                    isBad: (viewModel.statistics?.roundTripTimeMilliseconds ?? 0) > 150
                )
                Figure(
                    title: "LOSS",
                    value: viewModel.statistics?.packetLossPercent.map { String(format: "%.1f", $0) } ?? "–",
                    unit: "%",
                    isBad: (viewModel.statistics?.packetLossPercent ?? 0) > 2
                )
                Figure(
                    title: "JITTER",
                    value: viewModel.statistics?.jitterMilliseconds.map { "\(Int($0.rounded()))" } ?? "–",
                    unit: "ms",
                    isBad: (viewModel.statistics?.jitterMilliseconds ?? 0) > 30
                )
            }

            HStack(spacing: 8) {
                Figure(
                    title: "VONALAK",
                    value: "\(viewModel.configuration.channels.count { $0.isListening })",
                    unit: "/ \(viewModel.configuration.channels.count)",
                    isBad: false
                )
                Figure(
                    title: "AKTÍV",
                    value: "\(members.count { $0.isOnline })",
                    unit: "/ \(members.count)",
                    isBad: false
                )
                Figure(
                    title: "ESEMÉNY",
                    value: "\(events.problemCount)",
                    unit: "hiba",
                    isBad: events.problemCount > 0
                )
            }

            if viewModel.statistics == nil {
                // The figures come from LiveKit's per-track statistics, so
                // there is nothing to measure until audio is actually moving.
                // Saying "after connecting" would be wrong while connected.
                Text(viewModel.isConnected
                    ? "Nincs mérhető forgalom. A számok akkor jelennek meg, ha más is a vonalon van, vagy ha beszélsz."
                    : "A számok a kapcsolat felépülése után jelennek meg.")
                    .font(DS.display(12, .regular))
                    .foregroundStyle(DS.ink3)
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: "LEGROSSZABB KAPCSOLATOK", size: 11, color: DS.ink2)

            VStack(spacing: 0) {
                ForEach(worstLinks) { member in
                    HStack {
                        Text(member.displayName)
                            .font(DS.display(14, .regular))
                            .foregroundStyle(DS.ink)
                        Spacer()
                        MonoLabel(
                            text: member.quality.title,
                            size: 10,
                            weight: .bold,
                            color: member.quality <= .poor ? DS.live : DS.ink3
                        )
                    }
                    .padding(12)
                    .overlay(alignment: .bottom) {
                        Rectangle().frame(height: DS.hairline).foregroundStyle(DS.line.opacity(0.6))
                    }
                }
            }
            .background(DS.surface)
            .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
        }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MonoLabel(text: "ESEMÉNYNAPLÓ", size: 11, color: DS.ink2)
                Spacer()
                if !events.entries.isEmpty {
                    Button { events.clear() } label: {
                        MonoLabel(text: "TÖRLÉS", size: 10, weight: .bold, color: DS.ink3)
                    }
                    .buttonStyle(.plain)
                }
            }

            if events.entries.isEmpty {
                Text("Még nem történt semmi.")
                    .font(DS.display(12, .regular))
                    .foregroundStyle(DS.ink3)
            } else {
                VStack(spacing: 0) {
                    ForEach(events.entries) { entry in
                        EventRow(entry: entry)
                    }
                }
                .background(DS.surface)
                .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
            }

            Text("A napló csak a memóriában él, és a munkamenettel együtt elvész. Nem tartalmaz hangot, tokent és hitelesítő adatot.")
                .font(DS.display(11, .regular))
                .foregroundStyle(DS.ink3)
        }
    }
}

private struct Figure: View {
    let title: String
    let value: String
    let unit: String
    let isBad: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MonoLabel(text: title, size: 10, weight: .regular, color: DS.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(DS.mono(22, .bold))
                    .foregroundStyle(isBad ? DS.live : DS.ink)
                MonoLabel(text: unit, size: 10, weight: .regular, color: DS.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DS.surface)
        .overlay { Rectangle().stroke(isBad ? DS.live : DS.line, lineWidth: DS.hairline) }
    }
}

private struct EventRow: View {
    let entry: EventLog.Entry

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MonoLabel(
                text: Self.formatter.string(from: entry.date),
                size: 10,
                weight: .regular,
                color: DS.ink3
            )
            .monospacedDigit()

            VStack(alignment: .leading, spacing: 2) {
                MonoLabel(text: entry.code.title, size: 10, weight: .bold, color: colour)
                if let detail = entry.detail {
                    Text(detail)
                        .font(DS.display(12, .regular))
                        .foregroundStyle(DS.ink3)
                }
            }

            Spacer()
        }
        .padding(12)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: DS.hairline).foregroundStyle(DS.line.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
    }

    private var colour: Color {
        switch entry.severity {
        case .info: DS.ink
        case .warning: DS.accentText
        case .error: DS.live
        }
    }
}
