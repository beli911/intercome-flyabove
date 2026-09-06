import SwiftUI

/// Which production the operator is working on.
///
/// Shown only when there is more than one; a chooser with a single row is a
/// speed bump before a show, not a feature.
struct ProductionPickerView: View {
    @ObservedObject var environment: AppEnvironment
    var onSignOut: (() async -> Void)?

    @State private var highlighted: UUID?

    var body: some View {
        ZStack {
            DS.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(environment.productions) { production in
                            ProductionRow(
                                production: production,
                                isHighlighted: highlighted == production.id,
                                onTap: { highlighted = production.id }
                            )
                        }
                    }
                    .padding(14)
                }

                if let errorMessage = environment.errorMessage {
                    MonoLabel(text: errorMessage, size: 11, color: DS.live)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                HStack(spacing: 10) {
                    BlockButton(title: "KÓD BEOLVASÁSA") {
                        // Empty code: the sheet opens on the scanner.
                        environment.pendingInviteCode = ""
                    }
                    BlockButton(
                        title: environment.isBusy ? "BELÉPÉS…" : "BELÉPÉS ÉLŐBE",
                        isPrimary: true,
                        isEnabled: highlighted != nil && !environment.isBusy
                    ) {
                        guard let id = highlighted,
                              let production = environment.productions.first(where: { $0.id == id })
                        else { return }
                        Task { await environment.selectProduction(production) }
                    }
                }
                .padding(14)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                MonoLabel(
                    text: environment.user?.displayName ?? "OPERÁTOR",
                    size: 11,
                    color: DS.ink3
                )
                Text("Produkciók")
                    .font(DS.display(30, .bold))
                    .foregroundStyle(DS.ink)
            }

            Spacer()

            if let onSignOut {
                Button { Task { await onSignOut() } } label: {
                    MonoLabel(text: "KILÉP", size: 11, weight: .bold, color: DS.ink2)
                        .frame(width: DS.iconSize + 14, height: DS.iconSize)
                        .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: DS.hairline).foregroundStyle(DS.line)
        }
    }
}

private struct ProductionRow: View {
    let production: ProductionSummary
    let isHighlighted: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isHighlighted ? DS.accent : DS.surface2)
                    .frame(width: DS.channelBarWidth)

                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel(text: production.role, size: 11, color: DS.ink3)
                    Text(production.name)
                        .font(DS.display(17, .bold))
                        .foregroundStyle(DS.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)

                if isHighlighted {
                    MonoLabel(text: "✓", size: 15, weight: .bold, color: DS.accent)
                        .padding(.trailing, 14)
                }
            }
            .frame(minHeight: DS.controlHeight)
            .background(DS.surface)
            .overlay {
                Rectangle().stroke(isHighlighted ? DS.accent : DS.line, lineWidth: DS.hairline)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}
