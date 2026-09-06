# Vizuális rendszer

Forrás: „Flycom · mobil UX javaslat · v1" (*Broadcast pult a zsebben*).
Az implementáció a [`FlyAboveIntercom/UI/DesignSystem.swift`](../FlyAboveIntercom/UI/DesignSystem.swift)
fájlban él.

## A jel

Négy sáv, egy szintmérő — a hang maga, nem a mikrofon képe. Csak téglalapokból
áll, ezért 18 ponton és hímzésben is megmarad.

A sávmagasságok (24 : 40 : 56 : 32 a 96 pontos mesterben) szándékosan nem
szabályos lépcső: egy szótag közben elkapott szintmérő hangnak látszik, egy
szimmetrikus diagramnak.

Az app ikon fordított — sárga sávok fekete alapon —, mert a telefon a
legtöbbször sötét kezdőlapon és sötét pultban van. A felületen a jel sárga
lapon sötét sávokkal áll.

Egy forrás, két kimenet: `scripts/make-app-icon.swift` és a `FlycomMark` nézet
ugyanazokat az arányokat használja, törtekként megadva, hogy bármilyen méretben
azonos legyen.

## Három szabály

1. **A szín információt hordoz, nem díszít.** Sárga = élesített gomb, piros =
   nyitott mikrofon, zöld = ép kapcsolat. Minden más semleges, hogy a sötét
   gallériában a két számító szín félreérthetetlen maradjon.
2. **Kemény sarkok.** A lekerekítés 0–4 pt. Ez berendezésnek látszik, nem
   fogyasztói appnak, és a találati felület téglalap marad.
3. **Hüvelykujjnyi célpontok.** Amit vakon kell eltalálni, az 76 pt magas — jóval
   a 44 pt-os minimum felett.

## Paletta

| Token | Sötét | Napfény | Használat |
| --- | --- | --- | --- |
| `bg` | `#0B0B0C` | `#F5F5F2` | háttér |
| `surface` | `#16171A` | `#FFFFFF` | sorok, kártyák |
| `ink` / `ink2` / `ink3` | `#F5F5F2` + 62% / 66% | `#0B0B0C` + 62% / 55% | szöveg |
| `accent` | `#FFD400` | `#FFD400` | élesített gomb **háttere** |
| `accentText` | `#FFD400` | `#8A6D00` | akcentus **szövegként** |
| `live` | `#FF3B2F` | `#FF3B2F` | nyitott mikrofon |
| `ok` | `#2BD97C` | `#2BD97C` | ép kapcsolat |

A sárga napfény módban is sárga marad, de **csak háttérként**: világos alapon
sárga szöveg olvashatatlan, ezért a szöveges akcentus a sötétebb borostyánra
vált — ezt a javaslat maga is így használja a világos témájú linkjeinél.

## Tipográfia

A javaslat Archivót és IBM Plex Monót ír elő. Egyik sem része az iOS-nek, a
becsomagolásuk külön döntés, ezért a rendszerbetűk állnak helyettük: SF a
nevekhez és a prózához, SF Mono a gépi címkékhez. A lényegi megkülönböztetés —
proporcionális a neveknek, monospace az állapotnak és a vezérlőknek — így is
megmarad.

Nagybetűs mono címke csak vezérlőn, státuszon és szekciócímen van. A próza
mondatkezdő nagybetűvel áll; a felhasználónak írt mondatot nem kiabáljuk.

## Metrikák

| Elem | Méret |
| --- | --- |
| csatornasor és fő vezérlők | 76 pt |
| másodlagos, teljes szélességű gomb | 56 pt |
| fejléc ikongomb | 46 pt |
| TALK | 118 pt széles |
| LISTEN | 72 pt széles |
| csatorna színsáv | 6 pt |

## Mi készült el

| Javaslat | Állapot |
| --- | --- |
| 1a Bejelentkezés | kész, valódi auth-fal |
| 1c Meghívókód / QR | kész, QR-olvasóval és deep linkkel |
| 2a Produkcióválasztó | kész |
| 2c Crew | kész, valódi jelenléttel |
| 2b Intercom főképernyő | kész, momentary és latch PTT-vel |
| 2d Csatorna beállítás | részben: TALK mód, jogosultság, némítás |
| 2e Profil | részben: identitás, hang, téma, fejlesztői adatok, kijelentkezés |

## Mi nem készült el, és miért

A javaslat 13 képernyője közül a többi későbbi mérföldkőhöz tartozik, és a
backend sem támogatja őket:

- **1b regisztráció** — nincs önkiszolgáló regisztráció; a hozzáférést admin adja;
- **1d „adásra kész" ellenőrzőlista** — headset teszt, mikrofonszint;
- **3a–3d admin és monitoring** — M3.

A `CREW` és `ADMIN` fül látszik a fülsávon, de tiltott és megmondja, melyik
mérföldkőre vár. Ez őszintébb, mint elrejteni, és őszintébb, mint mintaadattal
feltölteni.

Ugyanez a csatorna beállításnál: a hangerő, az IFB ducking és a prioritás
jelzés fel van sorolva a mérföldkövével, de nincs hozzá kapcsoló. **Élő
intercomon egy döglött kapcsoló rosszabb, mint egy hiányzó.**

## Nyitott

- Archivo és IBM Plex Mono becsomagolása, ha a márkabetű fontos;
- a javaslat 1d „adásra kész" ellenőrzőlistája (headset teszt, mikrofonszint);
- napfény mód valódi kültéri ellenőrzése fizikai eszközön.
