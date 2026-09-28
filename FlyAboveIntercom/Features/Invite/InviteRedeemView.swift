import AVFoundation
import SwiftUI

/// Joining a production from an invite: scan the code, or type it.
///
/// Both paths exist because both happen. The QR is on a call sheet or a
/// screen; the four characters get read out over a talkback when the camera
/// cannot see it.
struct InviteRedeemView: View {
    @ObservedObject var environment: AppEnvironment
    /// Prefilled when the app was opened from an invite link.
    var initialCode: String = ""
    let onCancel: () -> Void

    @State private var code = ""
    @State private var isScanning = false
    @State private var scannerMessage: String?
    @FocusState private var isCodeFocused: Bool

    private var canSubmit: Bool { InviteCode.isComplete(code) && !environment.isBusy }

    var body: some View {
        ZStack {
            DS.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        scannerPane
                        manualEntry
                        if let message = scannerMessage {
                            MonoLabel(text: message, size: 11, color: DS.ink3)
                        }
                        if let errorMessage = environment.errorMessage {
                            MonoLabel(text: errorMessage, size: 11, color: DS.live)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }

                BlockButton(
                    title: environment.isBusy ? "CSATLAKOZÁS…" : "CSATLAKOZÁS",
                    isPrimary: true,
                    isEnabled: canSubmit
                ) {
                    Task { _ = await environment.redeemInvite(code: InviteCode.normalised(code)) }
                }
                .padding(14)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { code = InviteCode.normalised(initialCode) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                MonoLabel(text: "CSATLAKOZÁS", size: 11, color: DS.ink3)
                Text("Olvasd be a\nprodukció kódját")
                    .font(DS.display(26, .bold))
                    .foregroundStyle(DS.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: onCancel) {
                MonoLabel(text: "MÉGSE", size: 11, weight: .bold, color: DS.ink2)
                    .frame(width: DS.iconSize + 14, height: DS.iconSize)
                    .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: DS.hairline).foregroundStyle(DS.line)
        }
    }

    @ViewBuilder
    private var scannerPane: some View {
        ZStack {
            if isScanning {
                QRScannerView(
                    onCode: { value in
                        isScanning = false
                        if let scanned = codeFrom(value) {
                            code = scanned
                            Task { _ = await environment.redeemInvite(code: scanned) }
                        } else {
                            scannerMessage = "A beolvasott kód nem meghívó."
                        }
                    },
                    onUnavailable: { message in
                        isScanning = false
                        scannerMessage = message
                    }
                )
            } else {
                Button { startScanning() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 34))
                            .foregroundStyle(DS.ink2)
                        MonoLabel(text: "KÓD BEOLVASÁSA", size: 11, weight: .bold, color: DS.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 200)
        .background(DS.surface)
        .overlay { Rectangle().stroke(DS.line, lineWidth: DS.hairline) }
        // The reticle is drawn over whichever state is showing, so the framing
        // is the same before and during the scan.
        .overlay { Reticle() }
    }

    /// Accepts either a bare code or a full invite link.
    private func codeFrom(_ value: String) -> String? {
        if let url = URL(string: value), let code = InviteCode.from(url: url) { return code }
        let normalised = InviteCode.normalised(value)
        return InviteCode.isComplete(normalised) ? normalised : nil
    }

    private func startScanning() {
        scannerMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isScanning = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        isScanning = true
                    } else {
                        scannerMessage = "A kamera használata nincs engedélyezve. Írd be a kódot."
                    }
                }
            }
        default:
            scannerMessage = "A kamera használata nincs engedélyezve. Írd be a kódot."
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel(text: "VAGY ÍRD BE", size: 11, color: DS.ink2)

            // One field styled as four cells: a real four-field layout loses
            // the caret and breaks paste.
            ZStack(alignment: .leading) {
                HStack(spacing: 8) {
                    ForEach(0 ..< InviteCode.length, id: \.self) { index in
                        let characters = Array(InviteCode.normalised(code))
                        Text(index < characters.count ? String(characters[index]) : " ")
                            .font(DS.mono(24, .bold))
                            .foregroundStyle(DS.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(DS.surface)
                            .overlay {
                                Rectangle().stroke(
                                    index == InviteCode.normalised(code).count && isCodeFocused
                                        ? DS.accent
                                        : DS.line,
                                    lineWidth: DS.hairline
                                )
                            }
                    }
                }

                TextField("", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($isCodeFocused)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.go)
                    .onSubmit {
                        guard canSubmit else { return }
                        Task { _ = await environment.redeemInvite(code: InviteCode.normalised(code)) }
                    }
                    .onChange(of: code) { _, newValue in
                        let cleaned = InviteCode.normalised(newValue)
                        if cleaned != newValue { code = cleaned }
                    }
                    // Invisible rather than faint: at any opacity above zero
                    // the raw text shows through the first cell. It still takes
                    // focus, keystrokes and paste.
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .frame(height: 64)
                    .accessibilityLabel("Meghívókód")
            }
            .contentShape(Rectangle())
            .onTapGesture { isCodeFocused = true }
        }
    }
}

private struct Reticle: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height) * 0.55
            Path { path in
                let rect = CGRect(
                    x: (geometry.size.width - size) / 2,
                    y: (geometry.size.height - size) / 2,
                    width: size,
                    height: size
                )
                let arm = size * 0.22
                for corner in [
                    (rect.minX, rect.minY, 1.0, 1.0),
                    (rect.maxX, rect.minY, -1.0, 1.0),
                    (rect.minX, rect.maxY, 1.0, -1.0),
                    (rect.maxX, rect.maxY, -1.0, -1.0)
                ] {
                    let (x, y, dx, dy) = corner
                    path.move(to: CGPoint(x: x + arm * dx, y: y))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + arm * dy))
                }
            }
            .stroke(DS.accent, lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}
