---
description: Projekt-Status und Pipeline-Fortschritt anzeigen
argument-hint: <projektname>
---

Projekt: $ARGUMENTS

Zeige dem User einen kompakten Status für Projekt `$ARGUMENTS`:

1. Hole den Projekt-Snapshot über den Engine-MCP-Tool-Call
   `get_project_state(project_dir)`. Er liefert Modus, Budget, den
   Gate-Stand, Artefakt-Versionen, die nächste offene Phase und offene
   Shots in einem Aufruf.
2. Ausgabe als Markdown-Tabelle plus ASCII-Pipeline:

```
A1  Ingest        ── A2  analysis    ── K1  brief       ── K2  prod-design
 ✓                    ✓                   ○                   ○

──  K3  treatment ── K4  storyboard  ── K5  bible       ── K7  shotlist
    ○                 ○                   ○                   ○

──  S   sanity    ── F   frames      ── R1  preview     ── R2  final     ── Final
    ○                 ○                   ○                   ○                ○
```

Legende: `✓` approved, `○` pending, `✗` blocked (errors im Sanity-Report).
Der Gate-Stand für die Symbole kommt aus dem Snapshot.

Plus, wenn im Snapshot vorhanden:
- Anzahl Shots in der aktuellen Shotlist
- Anzahl freigegebener Frames
- Ausgegebenes Budget (spent EUR) — bei Bedarf über
  `estimate_cost(project_dir)` nachschlagen
- Letzte Modifikation der Artefakte (relative Zeiten), falls der Snapshot
  sie führt

Wenn ein Artefakt in einer Phase fehlt, das es laut Gate-Stand geben
müsste, flagge es.
