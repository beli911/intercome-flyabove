import SwiftUI

/// Profile and settings, trimmed to what the client can honestly change today.
struct ProfileView: View {
    @ObservedObject var viewModel: IntercomViewModel
    var onSignOut: (() async -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                identity
                audioSection
                displaySection
                if onSignOut != nil { accountSection }
                buildStamp
            }
            .padding(14)
        }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            MonoLabel(text: initials, size: 16, weight: .bold, color: DS.onAccent)
                .frame(width: 52, height: 52)
                .background(DS.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.configuration.displayName)
                    .font(DS.display(20, .bold))
                    .foregroundStyle(DS.ink)
                MonoLabel(
                    text: viewModel.canTalkOnAnyChannel ? "TALK + LISTEN" : "CSAK HALLGATÁS",
                    size: 11,
                    weight: .regular,
                    color: DS.ink3
                )
            }

            Spacer()
        }
    }

    private var initials: String {
        let words = viewModel.configuration.displayName.split(separator: " ")
        switch words.count {
        case 0: return "FA"
        // A single-word display name still deserves a two-letter badge.
        case 1: return String(words[0].prefix(2)).uppercased()
        default: return String(words.prefix(2).compactMap(\.first)).uppercased()
        }
    }

    private var audioSection: some View {
        Section(title: "HANG") {
            InfoRow(title: "Kimenet", value: viewModel.audioRouteName ?? "—")
            InfoRow(
                title: "Mikrofon",
                value: microphoneStatus,
                valueColor: viewModel.isMicrophoneGranted == false ? DS.live : DS.ink
            )
            InfoRow(title: "Alap TALK mód", value: viewModel.talkMode.title)
        }
    }

    private var microphoneStatus: String {
        switch viewModel.isMicrophoneGranted {
        case true: "Engedélyezve"
        case false: "Letiltva"
        case nil: "Még nem kértük"
        }
    }

    private var displaySection: some View {
        Section(title: "MEGJELENÍTÉS") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Téma")
                        .font(DS.display(14, .regular))
                        .foregroundStyle(DS.ink)
                    Spacer()
                }

                HStack(spacing: 8) {
                    ForEach(AppTheme.allCases) { theme in
                        Button { viewModel.theme = theme } label: {
                            MonoLabel(
                                text: theme.title,
                                size: 11,
                                weight: .bold,
                                color: viewModel.theme == theme ? DS.onAccent : DS.ink2
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(viewModel.theme == theme ? DS.accent : .clear)
                            .overlay {
                                if viewModel.theme != theme {
                                    Rectangle().stroke(DS.line, lineWidth: DS.hairline)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Napfény módban a kontraszt nő, a sárga sötét alapon marad.")
                    .font(DS.display(12, .regular))
                    .foregroundStyle(DS.ink3)
            }
            .padding(12)
            .overlay(alignment: .bottom) {
                Rectangle().frame(height: DS.hairline).foregroundStyle(DS.line.opacity(0.6))
            }

            Toggle(isOn: $viewModel.isDeveloperModeEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fejlesztői adatok")
                        .font(DS.display(14, .regular))
                        .foregroundStyle(DS.ink)
                    Text("RTT és útvonal a fejlécben")
                        .font(DS.display(12, .regular))
                        .foregroundStyle(DS.ink3)
                }
            }
            .tint(DS.accent)
            .padding(12)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: "FIÓK", size: 11, color: DS.ink2)
            BlockButton(title: "KIJELENTKEZÉS") {
                Task { await onSignOut?() }
            }
        }
    }

    private var buildStamp: some View {
        MonoLabel(
            text: "FLYABOVE INTERCOM \(Bundle.main.shortVersion)",
            size: 10,
            weight: .regular,
            color: DS.ink3
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 8)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(text: title, size: 11, color: DS.ink2)
            VStack(spacing: 0) { content }
                .background(DS.surface)
                .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
        }
    }
}

private struct InfoRow: View {
    let title: String
    let value: String
    var valueColor: Color = DS.ink

    var body: some View {
        HStack {
            Text(title)
                .font(DS.display(14, .regular))
                .foregroundStyle(DS.ink)
            Spacer()
            MonoLabel(text: value, size: 11, weight: .regular, color: valueColor)
        }
        .padding(12)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: DS.hairline).foregroundStyle(DS.line.opacity(0.6))
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) · BUILD \(build)"
    }
}
