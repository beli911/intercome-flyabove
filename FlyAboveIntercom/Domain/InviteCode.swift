import Foundation

/// The short code on an invite.
///
/// These get read aloud over a talkback and typed on a phone in the dark, so
/// the alphabet leaves out the characters people confuse: no O against 0, no I
/// or L against 1. Input is normalised rather than rejected — someone typing
/// "dm2p" or "DM 2P" meant the right thing.
enum InviteCode {
    static let length = 4
    static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func normalised(_ raw: String) -> String {
        String(raw.uppercased().filter { alphabet.contains($0) }).prefix(length).description
    }

    static func isComplete(_ raw: String) -> Bool {
        normalised(raw).count == length
    }

    /// Extracts a code from `flyabove-intercom://invite/DM2P` or from an https
    /// link ending in the code.
    static func from(url: URL) -> String? {
        let candidate: String?
        if url.scheme?.lowercased() == "flyabove-intercom" {
            // Both invite/CODE and //invite/CODE shapes occur depending on how
            // the link was written.
            let parts = ([url.host] + url.pathComponents).compactMap { $0 }
                .filter { $0 != "/" && $0.lowercased() != "invite" }
            candidate = parts.last
        } else {
            candidate = url.pathComponents.last
        }

        guard let candidate else { return nil }
        let code = normalised(candidate)
        return isComplete(code) ? code : nil
    }
}
