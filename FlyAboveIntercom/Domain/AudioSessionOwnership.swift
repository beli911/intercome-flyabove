import Foundation

/// Ki nyúlhat az `AVAudioSession`-höz, amíg a rendszer Push to Talk vonala él.
///
/// Ez a fájl azért létezik, mert két követelmény látszólag ellentmond egymásnak,
/// és a köztük lévő döntést eszköz nélkül nem lehet eldönteni:
///
/// - **A hallgatáshoz aktív munkamenet kell.** Az app ma a csatlakozáskor
///   aktiválja (`activate(recording: false)`), és ettől szól a fülhallgatóban a
///   többi vonal.
/// - **A rendszer PTT-aktiválásához viszont épp az a baj, ha már aktív.** A
///   `PTChannelManager` a gombnyomáskor maga aktiválja a munkamenetet és a
///   `didActivate` visszahívásban adja át; egy már aktív munkamenetet nem tud
///   újra aktiválni, tehát a visszahívás **hibaüzenet nélkül elmarad** — és a
///   mikrofon lezárt képernyőn csendben nem nyílik ki.
///
/// A LiveKit SDK saját doksija (`Docs/audio.md`) a CallKit-jellegű, magától
/// konfiguráló keretrendszerekre azt írja elő, hogy a SDK automatikus
/// konfigurációját ki kell kapcsolni — a Push to Talk ugyanez az osztály.
///
/// Amit ezzel a tudással **nem** lehet megtenni: kitalálni, melyik mód működik
/// egy valódi telefonon. Ezért ez a modul **két módot** ír le, nem egyet, és az
/// alapértelmezés az, amit ma mérünk — így a Push to Talk nélküli út
/// bizonyíthatóan változatlan.
enum AudioSessionOwnership {
    enum Mode: String, CaseIterable, Sendable {
        /// Ahogy ma működik: az app aktiválja és zárja a munkamenetet, a LiveKit
        /// automatikus konfigurációja bekapcsolva marad.
        case appOwns
        /// A dokumentált átadás: amíg a rendszer tart egy háttérvonalat, az app
        /// nem aktiválja és nem zárja a munkamenetet, és a LiveKit sem nyúl
        /// hozzá — a `PTChannelManager` adja át aktiválva.
        case systemOwnsDuringPushToTalk

        var title: String {
            switch self {
            case .appOwns: "AZ APP KEZELI"
            case .systemOwnsDuringPushToTalk: "A RENDSZER KEZELI (PTT)"
            }
        }
    }

    /// Megnyithatja-e az app maga a munkamenetet.
    ///
    /// Csak akkor nem, ha a rendszer tart egy háttérvonalat ÉS az átadó módban
    /// vagyunk. Háttérvonal nélkül — tehát Push to Talk képesség nélkül is —
    /// mindkét mód ugyanazt adja, és ez az a tulajdonság, amit a teszt kiköt.
    static func mayAppActivate(mode: Mode, isBackgroundLineHeld: Bool) -> Bool {
        switch mode {
        case .appOwns: true
        case .systemOwnsDuringPushToTalk: !isBackgroundLineHeld
        }
    }

    /// Lezárhatja-e az app a munkamenetet.
    ///
    /// Szándékosan ugyanaz a feltétel: egy munkamenet, amit nem mi nyitottunk,
    /// nem a miénk bezárni — és egy rendszer által tartott vonal alatt a
    /// lezárás pont az adást vágná el.
    static func mayAppDeactivate(mode: Mode, isBackgroundLineHeld: Bool) -> Bool {
        mayAppActivate(mode: mode, isBackgroundLineHeld: isBackgroundLineHeld)
    }

    /// Kikapcsolandó-e a LiveKit automatikus `AVAudioSession`-konfigurációja.
    ///
    /// A SDK doksija szerint ezt **egyszer, indulás közben** kell beállítani, és
    /// nem szabad menet közben változtatni — ezért ez a döntés a módból jön, nem
    /// abból, hogy épp tart-e valaki egy vonalat.
    static func shouldDisableLiveKitAutomaticConfiguration(mode: Mode) -> Bool {
        mode == .systemOwnsDuringPushToTalk
    }
}
