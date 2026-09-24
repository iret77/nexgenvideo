# Schnitt-Einstieg und manuelle Mediengenerierung

## Befund und Korrektur

Der bisherige Schnitt wurde nur bei `have.edit` aufgebaut. Der tatsächliche Übergang aus der Take-Freigabe setzte diesen Zustand noch nicht; eine zusätzliche „Takes in Schnitt übernehmen“-Ansicht versteckte den Editor. Direkte Schnitt-Fixtures hatten die Initialisierung bereits ausgeführt und erfassten diese Lücke nicht.

Der Schnitt zeigt jetzt grundsätzlich Viewer, Quellen und Timeline. Vor fertigen Takes bleibt die Sequenz ausdrücklich leer. Nach Take-Freigabe wird der vorhandene Rohschnitt initialisiert. Gespeicherte Übergangszustände werden ebenso behandelt; eine veraltete View im Workspace-Memory kann den Schnitt-Button nicht mehr zurück auf eine Produktionsansicht lenken. Bestehende Montage und Trims werden beim normalen Workspace-Wechsel erhalten.

## Vorhandener Generierungsweg im Code

- `Sources/NexGenVideo/Generation/UI/GenerationView.swift`: Bild/Video/Audio, Prompt, Modellwahl, Referenzeingänge, Dauern, Formate und Kostenschätzung sind bereits vorhanden. `isUsable` verknüpft aktivierte Modelle mit ausführbaren Providerbindungen. `submitGeneration` baut einen `GenerationRequest`; ohne explizites Ersetzen/Platzieren ist das Ziel die Medienbibliothek.
- `Sources/NexGenVideo/Generation/GenerationRequest.swift`: `GenerationController` bereitet die Generierung vor, prüft die Eingaben, hält kompilierten Prompt und Referenzen fest und erlaubt nur eine Einreichung pro vorbereitetem Auftrag. Diesen Pfad wiederverwenden.
- `Sources/NexGenVideo/Generation/Providers/FalModelRegistry.swift` und `RunwayModelRegistry.swift`: Grundlage der ausgewählten **Demo-Modelle**. ElevenLabs Sound Effects kann durch bestehende Providerbindungen direkt bzw. über fal laufen.

Der zusätzliche Einstieg **Medien → Generieren…** ist daher UI-Komposition um die bestehende Generierung. Die ausdrückliche Anbieterwahl muss an tatsächlich ausführbare Modell-/Transportbindungen gekoppelt werden. Kein neuer Provider-Client und kein direkter Versand des eingegebenen Prompts: Nutzereingabe bleibt Intent für die vorhandene Prompt-Engine.

## Clickdummy

Ein aufrufbarer Dialog mit Bild/Video/Audio, Anbieter, Modell, Prompt, passenden Optionen und Zielordner. Bild-zu-Video verlangt ein ausgewähltes Startbild; Text-zu-Video übernimmt keine versteckte Bildreferenz. Der genaue Auftrag wird vor der Freigabe mit Beispielkosten gezeigt. Leerer Prompt, fehlendes Startbild, paralleler Auftrag und unzureichendes Budget blockieren die Einreichung. Eine verbrauchte Freigabe kann nicht erneut starten.

Fertiggestellte Beispiele landen als freie Medien in derselben Bibliothek. Prompt, Anbieter, Modell und Beispielkosten sind im Inspector einsehbar. Die Produktion erhält keine automatische Shot-Zuweisung, Freigabe oder neue Phasenrevision. Abbruch vor Fertigstellung erzeugt kein Medium und berechnet im Dummy keine Beispielkosten. Reale Anbieter können bereits begonnene Generierung trotzdem berechnen; der Dummy modelliert keine Abrechnungs-API.

„Bilder“ steht als allgemeiner Medientyp neben den bestehenden Bildrollen Sketches und References. Generierte Beispiele sind klar bezeichnete Platzhalter. Ein beliebiger Prompt wird nicht mit einem unveränderten Claude-Mouse-Bild als angeblichem Ergebnis beantwortet. Die Auswahl eines freien generierten Videos zeigt diesen Platzhalter auch im Quellviewer; die NLE-Einfüge-Demo bleibt auf Shot-Takes begrenzt.

## Review vor Präsentation

Gerenderte Schnittansicht, Generierungseinstieg, Eingabedialog, Kostenblatt, Ergebnis und 320-px-Ansicht tatsächlich betrachtet. Der Schnitt behält das zuvor gegen Resolve/FCP geprüfte NLE-Layout; die neue Generierung ist ein lokaler Dialog ohne weitere globale Zeile oder Chatfenster. Auswahl bleibt über gefüllte Flächen erkennbar; der transparente Ein-Pixel-Rand der Medienkacheln wurde entfernt, da die Auswahlfläche darunter wie eine farbige Umrandung wirkte.

Mit echten Maus-/Tastatureingaben überprüft: Produktion → Schnitt, Take-Freigabe → gefüllte Montage, Prompt eingeben, Kosten prüfen, Auftrag auslösen, Ergebnis und Herkunft im Inspector. Dialoglayouts bei 1024, 736, 500 und 320 px ohne horizontalen Überlauf. Ablaufprüfungen ergänzen Providerwechsel, Startbildpflicht, Bild/Video/Audio-Ergebnisse, Abbruch, Budget, doppelte Einreichung und Wiederherstellung aus Schema 8.

Belege: `generation-workspace-checks.json`, `desktop-workbench-checks.json`, `desktop-workbench-layouts.json`. Nur Mockup und zugehörige Prüf-/Reviewdateien geändert; keine echten Generierungen, nativen Builds, App-Starts oder Dev-Server.
