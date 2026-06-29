---
description: Projekt zu einem früheren Gate zurückspulen (inkl. aller folgenden Gates)
argument-hint: <projekt> <gate> [note]
---

Argumente: $ARGUMENTS

Der User will einen Pipeline-Schritt überarbeiten — entweder weil sich
etwas am Brief geändert hat (z.B. neuer Modus), weil eine Freigabe
voreilig erfolgt ist, oder weil ein Artefakt neu generiert werden soll.

## Ablauf

1. Parse Argumente. Erwartet werden `<projekt> <gate> [note...]`.
   - `projekt` = Projektname im Projekt-Home (über
     `get_project_state(project_dir)` auflösbar).
   - `gate` = einer von `project_init | analysis | brief | production_design | treatment | storyboard | bible | shotlist | sanity | frames | videos_preview | videos_final`. Die kanonische Liste liefert `list_phases()`.
   - Optional: freier Text als Begründung (wird in die Gate-Notes geschrieben).
2. Wenn der User keine oder unklare Argumente geliefert hat: `AskUserQuestion`
   zur Präzisierung. Bei mehreren offenen Projekten ggf. zuerst per Picker
   das Projekt wählen lassen.
3. Vor dem Zurücksetzen **zeige dem User** welche Gates getroffen werden
   (Ziel-Gate + alle folgenden) und was das bedeutet — Beispiel:
   ```
   Rewind way_in_life → shotlist
   Zurückgesetzt werden: shotlist, sanity, frames, videos_preview, videos_final
   Artefakte bleiben (Versionierung), nur die Gates werden entwertet.
   ```
4. `AskUserQuestion` "bestätigen / abbrechen".
5. Bei Bestätigung: den Engine-MCP-Tool-Call
   `rewind(project_dir, target_phase)` ausführen. Optional die Begründung
   anschließend per `approve_gate`-Notes festhalten, falls relevant. Der
   Call gibt die zurückgesetzten Phasen (`reset_phases`) zurück.
6. Ausgabe anzeigen (welche Gates zurückgesetzt wurden — aus
   `reset_phases`).
7. Empfehlung: direkt mit `/continue <projekt>` weitermachen — die
   passende Phase läuft automatisch neu.

## Wichtig

- Artefakte (shotlist/vN.yaml, treatment/vN.md, bible.yaml, frames-PNGs,
  Render-Videos) werden **nicht** gelöscht. Alte Versionen bleiben als
  Historie; die Phasen schreiben beim Neu-Lauf eine neue Versionsnummer.
- **Kein direktes Editieren** der Gate-Datei per Write/Edit hinter den
  Kulissen. Gate-Mutationen laufen über die Engine-MCP-Tools (`rewind`,
  `approve_gate`), damit jede Änderung nachvollziehbar bleibt.
- Wenn der User ein einzelnes Feld in einem Artefakt ändern will
  (z.B. nur `project_mode` im Brief), dann:
  1. Frage ihn per AskUserQuestion, ob er tatsächlich das ganze Gate
     zurückspulen will (neuer Durchlauf der zuständigen Phase) oder ob
     ein inline-Edit reicht.
  2. Bei inline-Edit: zeige ihm den aktuellen Wert, frage nach dem neuen,
     schreibe das Artefakt selbst (eine klar umrissene Änderung ist ok,
     aber dokumentiere sie in den Gate-Notes).
  3. Danach `/rewind` für das **nachgelagerte** Gate ausführen, damit die
     betroffene Phase neu läuft.
