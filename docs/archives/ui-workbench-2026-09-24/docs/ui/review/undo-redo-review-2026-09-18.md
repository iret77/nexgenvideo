# Rückgängig und Wiederholen — Recherche und Review

Der alleinstehende Rückgängig-Button neben dem Projektnamen entfällt. Dies ist eine Entscheidung für diesen Entwurf, kein generelles Verbot von Undo-/Redo-Buttons in Mac-Apps.

## Quellen

- [Apple HIG: Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo), Inhalt über die [offizielle japanische Fassung](https://developer.apple.com/jp/design/human-interface-guidelines/undo-and-redo) geprüft: zusätzliche Buttons nur bei Bedarf; ansonsten Systemwege wie Bearbeiten-Menü und Tastenkürzel. Falls Buttons erforderlich sind, Standardsymbole in der Werkzeugleiste verwenden.
- [Apple HIG: Edit menus](https://developer.apple.com/design/human-interface-guidelines/edit-menus?changes=__5&language=objc): redundante Bedienelemente für vorhandene Menübefehle im Allgemeinen vermeiden. Das ist eine Empfehlung mit Ausnahmen.
- [Final Cut Pro für Mac: Tastaturbefehle](https://support.apple.com/nl-nl/guide/final-cut-pro/ver90ba5929/mac): Rückgängig mit ⌘Z, Wiederholen mit ⇧⌘Z. [Projekte sichern](https://support.apple.com/en-ca/guide/final-cut-pro/ver79aa3d71/mac) nennt außerdem Edit > Undo.
- [DaVinci Resolve 20: offizieller Editor’s Guide](https://documents.blackmagicdesign.com/UserManuals/DaVinci-Resolve-20-Editors-Guide.pdf): Edit > Undo / Command-Z. Der indexierte Handbuchtext wurde geprüft; daraus wird keine Aussage über die Abwesenheit sämtlicher Undo-Buttons in Resolve 21 abgeleitet.

## Entscheidung und Abgleich

Die Titelleiste braucht diesen zusätzlichen Befehl nicht. Das bisherige Unicode-Zeichen ↶ ist zudem kein bewusst gewähltes Standard-Werkzeugsymbol. Entfernt wurden Button und ausschließlich dafür verwendete Stile. Kein Ersatzbutton, kein neues Dropdown und keine zusätzliche Werkzeugzeile.

NexGenVideo bietet Undo und Redo bereits in `Sources/NexGenVideo/App/MainMenu.swift` im nativen Edit-Menü mit den üblichen Tastenkürzeln an. Diese App-Funktionen bleiben bestehen. Der Clickdummy stellt ein App-Fenster dar, nicht die außerhalb liegende macOS-Menüleiste; er simuliert beide Tastenkürzel. Der native Code wurde nicht verändert oder lokal ausgeführt.

## Self-Review und Verifikation

- Alle fünf Arbeitsbereiche ohne globalen Undo-/Redo-Button in der Titelleiste geprüft.
- Belichtung geändert, über ein tatsächliches Browser-Tastaturereignis mit ⌘Z zurückgenommen und mit ⇧⌘Z wiederhergestellt.
- Arbeitsbereich blieb bei beiden Operationen erhalten; Eingaben in Textfeldern werden nicht vom globalen Undo abgefangen.
- Medien und Postproduction bei 1.048 px Browserbreite visuell geprüft: Projekttitel, Modusreiter und beide Panel-Schalter bleiben getrennt und erreichbar. Kein leerer Platzhalter für den entfernten Button.
- Screenshots: `studio-screenshots/undo-titlebar-media.png` und `studio-screenshots/undo-titlebar-post.png`.

Die fünf gezielten Browserprüfungen bestanden. Die vorhandene Undo-/Redo-Simulation wurde beibehalten; dies ist kein vollständiger Test des nativen macOS-Responders oder sämtlicher Bearbeitungsaktionen.
