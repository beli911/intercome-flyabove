import Foundation

/// Nyomkövetés, ami akkor is megvan, ha senki nem figyelte.
///
/// Ez a fájl egy megégetett tanulságból született. Előbb `print`-tel próbáltuk:
/// az a stdout-ra megy, amit egy telefonon KIZÁRÓLAG az a folyamat ad vissza,
/// amit a `devicectl` maga indított — ha a felhasználó az ikonról indítja újra
/// az appot, a nyom nyomtalanul elvész. A szimulátoron pedig a rendszernapló
/// streamelése a `print`-et eleve nem látja.
///
/// Egy diagnosztika, ami attól függ, hogyan indították az appot, nem
/// diagnosztika. Ezért ez fájlba ír, az app saját könyvtárába, ahonnan bármikor
/// leszedhető — futás közben, utólag, újraindítás után is.
enum FlycomDiagnostics {
    /// A fájl neve rögzített, mert egy eszköz, amit meg kell keresni, nem eszköz.
    static let fileName = "flycom-diag.log"

    private static let queue = DispatchQueue(label: "hu.flyabove.intercom.diag")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        // A konzolra is: ahol épp van figyelő, ott azonnal látszik.
        print("[Flycom] \(message)")
        queue.async {
            guard let url = fileURL, let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // A végére, hogy egy munkamenet ne törölje az előzőt: épp az
                // előző futás nyoma az, amit egy "már megint elromlott"
                // pillanatban keresni fogunk.
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Egy sor, ami megmondja, hogy a napló egyáltalán él-e, és honnan jön.
    static func logSessionStart() {
        log("--- indulás · \(Bundle.main.bundleIdentifier ?? "?") · \(fileURL?.path ?? "nincs fájl") ---")
    }
}
