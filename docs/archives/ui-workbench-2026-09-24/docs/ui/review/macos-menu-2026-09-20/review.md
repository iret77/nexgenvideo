# macOS-Menüs im Clickdummy

Die simulierte Menüleiste steht oberhalb des getrennten Projektfensters. Ablage bleibt die belegte deutsche Apple-Bezeichnung. Darstellung enthält Pane-Schalter und Layout, Fenster enthält das Projekt und die vorhandenen Aktivitätsanzeigen. Der Projektname bleibt reiner Text.

Bearbeiten verbindet Ausschneiden, Kopieren, Einsetzen, Löschen und Alles auswählen mit dem fokussierten Textfeld oder der Timeline. Teilen und Trimmen verwenden bestehende NLE-Aktionen. Gesperrte Spuren und der Postproduction-Kontext sperren Montageaktionen. Die Zwischenablage ist eine sitzungsinterne Simulation.

69 Browserprüfungen bestanden, einschließlich aller fünf Arbeitsbereiche, Textauswahl, Clip-Instanzen, Undo/Redo, gesperrter Spuren, Dialogfokus, Aktivitäten und Layoutbreiten. Zwei Testaufbauten wurden berichtigt: Zustandskopien sind nicht mutierbare App-Zustände; Menübefehle müssen im offenen Menü statt über gleichnamige Toolbar-Buttons gewählt werden.

Visuell geprüft: edit-menu.png, media.png und settings.png. Menütexte passen auf gemeinsame Achsen; der Fensterrahmen ist von der Menüleiste getrennt; Moduswahl und Inspector behalten ihre Positionen. Die Clipboard- und Betriebssystemsimulation ist keine native Laufzeitprüfung. Keine Swift-Dateien geändert, keine native App gebaut oder gestartet.

Quellen:
- https://support.apple.com/de-de/guide/mac-help/mchlp1446/mac
- https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
- https://developer.apple.com/design/human-interface-guidelines/toolbars

Die frühere Behauptung, ein Dokumentmenü sei wegen doppelter Erreichbarkeit grundsätzlich falsch, ist korrigiert: Apple erlaubt Dokumentmenüs. Das unspezifische Sammelmenü wird hier weiterhin nicht angeboten.
