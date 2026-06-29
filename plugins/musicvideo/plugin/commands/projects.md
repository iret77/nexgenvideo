---
description: Alle Projekte auflisten mit Kurz-Status
---

Liste alle Projekte im Projekt-Home auf. Ein leichtes Verzeichnis-Listing
des Home-Ordners genügt, um die Projektnamen zu finden; ignoriere
`_example`.

Für jedes gefundene Projekt:
1. Hole den Snapshot über den Engine-MCP-Tool-Call
   `get_project_state(project_dir)` — daraus kommen Modus, Budget, das
   letzte approved Gate und die nächste offene Phase.
2. Für den ausgegebenen Betrag (spent EUR): `estimate_cost(project_dir)`.

Ausgabe als Markdown-Tabelle, Spalten:
Projekt | Modus | Budget | Zuletzt approved | Nächste Phase | Ausgegeben

Nach der Tabelle ein Hinweis, wie der User fortsetzen kann:
```
/continue <projektname>   # Pipeline an nächster Phase fortsetzen
/status <projektname>     # Detail-Status
/start                    # Neues Projekt
```
