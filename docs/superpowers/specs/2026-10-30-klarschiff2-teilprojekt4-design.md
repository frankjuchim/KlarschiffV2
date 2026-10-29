# Klarschiff 2 – Teilprojekt 4: Hintergrunddienste

**Stand:** 30.10.2026 · **Grundlage:** `docs/Briefing.md` §2 „Tab Hintergrunddienste“, Screenshot `docs/screenshots/06-hintergrunddienste.webp`, Specs TP1–TP3
**Status:** Von Claude in der Nacht autonom entschieden (Frank: „Entwicklung über Nacht komplett fortführen, Ziel ist klar“). Jede Entscheidung steht in §2 und kann geändert werden.

## 1. Ziel und Erfolgskriterium

Der Tab **„Hintergrunddienste“** listet alle LaunchAgents/-Daemons (ohne Apple) und Anmeldeobjekte, erklärt sie, erkennt **verwaiste** Dienste (deren Programm bzw. App fehlt) und entfernt diese nach Bestätigung sauber. Nicht verwaiste Dienste werden nie entfernt – nur erklärt, mit Verweis auf die zuständige App bzw. die Systemeinstellungen.

**Abnahme:** Auf Franks Mac (lesend) zeigt der Tab alle Einträge aus `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` und die Anmeldeobjekte aus `sfltool dumpbtm` mit Bereich, Startart, „läuft gerade“ und „App ist installiert“; verwaiste Einträge werden korrekt erkannt (Trockenlauf-Entfernen läuft durch).

## 2. Entscheidungen (autonom, 30.10.2026)

| Frage | Entscheidung | Begründung |
|---|---|---|
| Quellen | `~/Library/LaunchAgents` (**Benutzer**), `/Library/LaunchAgents` (**Alle Benutzer**), `/Library/LaunchDaemons` (**System**), Anmeldeobjekte aus `sfltool dumpbtm` (Typ `login item`) als **Anmeldeobjekt** | Briefing §2; `/System/Library` und `com.apple.*` bleiben außen vor (gehört zu macOS). |
| Was ist „verwaist“? | Programmpfad (`Program`, `ProgramArguments[0]`, bei `BundleProgram` die App aus `AssociatedBundleIdentifiers`) existiert nicht **oder** die zugehörige App (Pfad in `*.app`, sonst `AssociatedBundleIdentifiers`) ist nicht installiert | Klarschiff 1 machte es so; konservativ: unklarer Fall → nicht verwaist. |
| Was darf entfernt werden? | **Nur verwaiste** LaunchAgents/-Daemons. Anmeldeobjekte nie (nur Hinweis + Knopf zu Systemeinstellungen → Anmeldeobjekte). | Sicherheit, Regel „nie automatisch“. |
| Wie entfernen? | Benutzer: `launchctl bootout gui/<uid>/<label>` + plist in den Papierkorb. Alle Benutzer/System: **Admin** (eine Passwortabfrage, TP1-Mechanik): `launchctl bootout system/<label>` (nur Daemons) bzw. `gui/<uid>/<label>` ohne Admin (Agents in `/Library/LaunchAgents` laufen im Benutzerkontext), dann `/bin/rm -f /Library/Launch{Agents,Daemons}/<datei>.plist`. | `rm` braucht für `/Library/…` Root; bootout so eng wie möglich. |
| Vorauswahl | Keine. Risiko „Prüfen“. Bestätigung mit rotem Hinweis wie TP2 (Häkchen) für Admin-Schritte. | Konsistent mit TP2. |
| „Läuft gerade“ | `launchctl print gui/<uid>/<label>` bzw. `system/<label>` (lesend, ohne Admin): Exit 0 und `state = running` | Beobachtet auf Franks Mac. |
| Startart | `RunAtLoad`/`KeepAlive` → „startet bei der Anmeldung“; `StartInterval`/`StartCalendarInterval` → „startet zeitgesteuert“; sonst „startet bei Bedarf“ | Briefing nennt zwei, „zeitgesteuert“ ergänzt (Klarschiff-Check selbst ist so einer). |
| Automatischer Check (TP3) | Neuer Alert `.orphanedServices(labels:)` wenn seit dem letzten Check **neue** verwaiste Dienste dazukamen (Priorität nach Wachstum, vor knappem Speicher) | TP3-Spec §2 hatte das für TP4 vorgesehen. |
| Klarschiff 2 selbst | Eigene Agents `de.frankjuchim.klarschiff2.*` erscheinen als „Klarschiff 2 – automatischer Check“ und sind nie verwaist/entfernbar | Selbstschutz. |

## 3. Kern (KlarschiffCore, Ordner `Services/`)

- **`LaunchItem`**: `id` (`scope/label`), `label`, `scope` (`.user`, `.allUsers`, `.system`, `.loginItem`), `plistURL?`, `programPath?`, `associatedBundleIDs: [String]`, `appURL?` (gefunden), `startKind` (`.atLogin`, `.scheduled`, `.onDemand`), `isRunning`, `isOrphaned`, `isOwnAgent`, `displayName` (App-Name aus `appURL` bzw. Label ohne Reverse-DNS-Präfix, z. B. „Stream Deck“), `explanation`.
- **`LaunchItemScanner`**: liest die drei Ordner über `ScanContext` (`ctx.homePath`, `ctx.absolute`), parst plists (fehlerhafte plist → Eintrag mit Hinweis „konnte nicht gelesen werden“, nie verwaist), überspringt `com.apple.*`, prüft Existenz der Pfade (Root-Prefix für Tests), App-Installation über injizierbares `isInstalled(bundleID)` (Produktion `NSWorkspace`), Laufstatus über `CommandRunner` (`/bin/launchctl print …`, Timeout 5 s, parallel begrenzt auf 8).
- **`LoginItemReader`**: `/usr/bin/sfltool dumpbtm` über `CommandRunner` (Timeout 20 s), parst die Abschnitte der aktuellen UID (`Records for UID <uid>`), nimmt nur Einträge mit `Type: login item` (Einträge `Type: app` sind nur Eltern-Container und dienen der Namensauflösung über `Parent Identifier`), dedupliziert nach `Identifier`; „startet bei der Anmeldung“ nur bei `Disposition` mit `enabled` **und** `allowed`, sonst „ausgeschaltet“. Fehler → leere Liste + Hinweis.
- **`ServiceRemovalBuilder`**: erzeugt aus gewählten verwaisten Einträgen einen `Finding` (Kategorie neu `services`, Tab `.services`) mit `.trash`-Items (Benutzer-plists) bzw. `.admin`-Schritten; plus Liste der nötigen `bootout`-Aufrufe ohne Admin. Nur Einträge mit `isOrphaned && !isOwnAgent && scope != .loginItem`.
- **`ServiceBootout`**: wie `LegacyAutomation.bootout` (TP3): nur `bootout gui/<uid>/<label>` für geladene Benutzer-/Alle-Benutzer-Agents; „nicht gefunden“ = erledigt; Trockenlauf → keine Aufrufe.
- **SafetyGuard/Admin (Erweiterung, eng):** SafetyGuard erlaubt direkte Kinder `*.plist` von `/Library/LaunchAgents` und `/Library/LaunchDaemons` (nicht die Ordner, keine Unterordner). AdminRemover-Allow-Liste: zusätzlich `/bin/launchctl` mit exakt `["bootout", "system/<label>"]`, `label` passt auf `^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$` und beginnt nicht mit `com.apple.`; `/bin/rm` unter `/Library/LaunchAgents|LaunchDaemons` nur Option `-f` und nur direkte `.plist`-Kinder.

## 4. Oberfläche (ersetzt den Platzhalter)

- **Kopfkarte**: große Zahl „X verwaiste Hintergrunddienste“ (bzw. „Keine verwaisten Hintergrunddienste“), Untertitel „Dienste, deren App gelöscht wurde, laufen sonst weiter oder starten ins Leere.“; Knöpfe **„Neu prüfen“** und **„Entfernen“** (nur verwaiste ausgewählte; öffnet den Bestätigungsdialog).
- **Abschnitt „Verwaist“** (nur wenn vorhanden): Karten mit Auswahlkreis, Name, Bereich-Pille, Label (monospaced), Pfad des fehlenden Programms („Programm fehlt: …“), „Befehl anzeigen“.
- **Abschnitt „Aktiv“**: alle übrigen Einträge, gruppiert nach Bereich (Benutzer / Alle Benutzer / System / Anmeldeobjekt): Name, „App ist installiert.“ bzw. „Gehört zu keiner App“ (neutral), Label, Startart, grüner Punkt „läuft gerade“, Lupe (plist bzw. App im Finder zeigen). Keine Auswahl.
- **Hinweiskarte Anmeldeobjekte**: „Anmeldeobjekte schaltest du in den Systemeinstellungen ein und aus.“ + Knopf (öffnet Anmeldeobjekte).
- Messung beim ersten Öffnen des Tabs und über „Neu prüfen“ (Muster TP2: unstrukturierter Task, gesperrt während Scan/Entfernen/Check).
- Bestätigungsdialog: bekannter ConfirmSheet; bei Admin-Schritten roter Hinweis + Häkchen (TP2-Mechanik, Kategorie `services` zählt wie `systemData`).

## 5. Sicherheit

- Nichts wird ohne Bestätigung entfernt; nur verwaiste, nicht-Apple, nicht-eigene Einträge; Anmeldeobjekte nie.
- Alle Dateioperationen über SafetyGuard; Admin nur über die erweiterte Allow-Liste; Trockenlauf wirkt überall.
- Lesende Werkzeuge: `launchctl print`, `sfltool dumpbtm`; schreibend nur `launchctl bootout`.

## 6. Tests

Fixture-Ordner mit plists (Programm vorhanden/fehlt, App installiert/nicht, BundleProgram + AssociatedBundleIdentifiers, defekte plist, com.apple.*), aufgezeichnete `launchctl print`-Ausgaben (läuft / „Could not find service“), aufgezeichnete `sfltool dumpbtm`-Ausgabe (von Franks Mac, anonymisiert auf Typ/Name/Identifier), Startart-Ableitung, Removal-Builder (nur verwaiste, eigene nie), Admin-Allow-Liste (erlaubte/verbotene launchctl-/rm-Formen), SafetyGuard-Erweiterung, Check-Alert für neue verwaiste Dienste, App: Laden beim ersten Öffnen, Entfernen-Reihenfolge (bootout → Papierkorb → Admin), Trockenlauf ohne Aufrufe.
