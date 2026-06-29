---
description: Budget-/Kosten-Stand eines Projekts
argument-hint: <projektname>
---

Projekt: $ARGUMENTS

Ermittle den Projektnamen aus $ARGUMENTS. Hole den Budget-Stand über den
Engine-MCP-Tool-Call:

`estimate_cost(project_dir)`

Der Call liefert das Budget-Bild aus dem Render-Ledger:
`budget_eur`, `spent_eur`, `remaining_eur`, `over_budget`.

Gib dem User das Ergebnis als kompakte Tabelle aus und kommentiere:
- Wie viel vom Budget ist verbraucht, wie viel bleibt?
- Liegt das Projekt im Budget oder ist `over_budget` gesetzt?
- Reicht der Rest-Spielraum (`remaining_eur`) für die noch offenen
  Render-Phasen?

Bei over-budget oder knappem Rest: konkrete Vorschläge, wo gespart werden
kann (günstigere Modell-Route pro Shot, Preview überspringen, Auflösung
auf 720p für mobile-only). Eine Vorab-Schätzung pro Shot liefert die
Render-Phase (Pass 2); `estimate_cost` ist der Ledger-Stand, keine
Forward-Schätzung.
