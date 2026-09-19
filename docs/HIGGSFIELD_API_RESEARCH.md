# Higgsfield REST API — Integration

Stand: 19. September 2026. Implementiert; authentifizierte Live-Abnahme noch offen.

## Zugang

Unter Settings → Providers → Higgsfield das API-Credential-Paar als
`KEY_ID:KEY_SECRET` speichern. Die macOS-Keychain hält die Credentials; der native
Host sendet `Authorization: Key …` an `https://api.higgsfield.ai`.
API und MCP/OAuth bleiben unabhängig nutzbar und besitzen getrennte Katalogangebote.
API-Guthaben in USD ist vom Website-Abonnement getrennt.
[Authentifizierung](https://docs.higgsfield.ai/docs/authentication),
[API-Produkt](https://www.higgsfield.company/creator-hub/help-center/integrations/what-is-the-higgsfield-api).

## Discovery und Quellenlage

Der öffentliche Console-Katalog liefert unter
[`dash.higgsfield.ai/api/v2/pricing/models/?page_size=50`](https://dash.higgsfield.ai/api/v2/pricing/models/?page_size=50)
Modellfamilien und exakte Modus-Slugs mit `availability_state`. Diese URL wurde aus
dem ausgelieferten Console-Client ermittelt und mit HTTP 200 live abgerufen.
Die Integration folgt validierten Pagination-URLs, wertet nur `available` aus und
schneidet das Ergebnis mit den implementierten Adaptern. Ein kostenloser
Estimate-Aufruf prüft anschließend die API-Verbindung. Eine fehlende oder abgelehnte
Verbindung veröffentlicht keine neuen API-Angebote. Vorübergehende Fehler erhalten
den letzten Katalog mit einem Hinweis auf den ausstehenden Refresh.

Das ist **ein öffentlicher Modellkatalog, keine accountbezogene Berechtigungsliste**.
Die Route-Receipts bezeichnen ihn entsprechend als `model_catalog`. Jede Generierung
prüft vor dem kostenpflichtigen POST die Schätzung für ihren konkreten Request.
Weder Katalogpräsenz noch ein erfolgreicher Estimate beweisen eine erfolgreiche
Generierung. Der nicht als öffentliche REST-Spezifikation dokumentierte
Console-Katalog bleibt eine externe Abhängigkeit, deren Schemaänderungen einen
fehlgeschlagenen Refresh auslösen können.

Offizielle [OpenAPI](https://docs.higgsfield.ai/docs/openapi.json) und
[Quellenhierarchie](https://docs.higgsfield.ai/docs/llms.txt) wurden geprüft; OpenAPI
enthält nicht alle angebotenen Modelle. Modellparameter stammen aus dem
`input_schema` der jeweiligen offiziellen Console-Seite. Einige sichtbare Tabellen
lassen Felder weg, die dieses eingebettete Schema ausdrücklich definiert.

## Implementierte Modelle

REST-Katalog-IDs beginnen mit `higgsfield/api/`; MCP-IDs bleiben unverändert.

| Modell/Modus | Vertrag |
| --- | --- |
| [Soul 2](https://console.higgsfield.ai/models/higgsfield-ai/soul/v2/standard/api-reference) | `higgsfield-ai/soul/v2/standard`; Text zu Bild, 720p/1080p, ein Bild pro Request; `enhance_prompt=false` erhält den kompilierten Prompt |
| [Seedance 2.5 Text](https://console.higgsfield.ai/models/bytedance/seedance-2.5/text-to-video/api-reference) | `bytedance/seedance-2.5/text-to-video`; 4–30 Sekunden, 480p/720p, Seitenverhältnis und Audio |
| [Start-/Endframe](https://console.higgsfield.ai/models/bytedance/seedance-2.5/image-to-video/api-reference) | `image-to-video`; erforderliches `image_url`, optionales `end_image_url`; kein `aspect_ratio` |
| [Referenzen](https://console.higgsfield.ai/models/bytedance/seedance-2.5/reference-to-video/api-reference) | `reference-to-video`; mindestens eine Referenz; bis 30 Bilder, 10 Videos und 10 Audios |
| [Edit](https://console.higgsfield.ai/models/bytedance/seedance-2.5/video-edit/api-reference) | `video-edit`; exaktes freigegebenes `video_url`, optionale Referenzen; kein `duration` oder `aspect_ratio` |
| [Extend](https://console.higgsfield.ai/models/bytedance/seedance-2.5/video-extend/api-reference) | `video-extend`; exaktes Vorgängervideo, 4–30 Sekunden, optionale Referenzen; kein `aspect_ratio` |

Die letzten vier Slugs tragen ebenfalls `bytedance/seedance-2.5/` als Präfix.
Alle Videomodi verwenden das im Schema bestätigte `bitrate_mode=high` und die
MP4-Standardausgabe. Soul erlaubt upstream Batchgrößen 1 oder 4; NexGenVideo bietet
zunächst nur 1 an, weil sein Bildzahl-Control einen lückenlosen Wertebereich voraussetzt.
Weitere Higgsfield-Familien werden erst mit eigenem Request-Adapter angeboten.

Prompt-Compile, Budgetfreigabe und Medien-Lineage laufen über den bestehenden
Host-Pfad für beide Agent-Backends. Frame-Continuation bindet den exakten letzten
Frame, native Extension das freigegebene Vorgängervideo. Öffentliche Pack-Layouts
wurden nicht verändert. Der praktische Ergebniszuschnitt und die Dauersemantik von
Extend müssen bei der authentifizierten End-to-End-Abnahme geprüft werden.

## Aufträge, Medien und Kosten

- Submission speichert `request_id`, `status_url`, `cancel_url` im Spend-Log. Recovery
  pollt diesen Auftrag und erzeugt keinen neuen kostenpflichtigen POST. Bei einem
  unklaren Submission-Ergebnis wird kein automatischer Wiederholungsversuch gestartet.
- Status behandelt `queued`, `in_progress`, `completed`, `failed`, `nsfw`, `canceled`.
  GET-Polling besitzt Backoff, Jitter, ein Zeitlimit und begrenzte Wiederholungen bei
  Netzwerkfehlern/429/5xx. Ein Polling-Fehler beendet nicht den Auftrag beim Anbieter.
- Cancel bestätigt nur HTTP 202. Ein bereits gestarteter Auftrag kann abgelehnt werden;
  die App behauptet in diesem Fall weder Abbruch noch Kostenfreiheit.
- Referenzen werden über `/files/generate-upload-url` und anschließend PUT mit exakt
  den zurückgegebenen Storage-Headern hochgeladen. Der Storage-Request enthält keine
  API-Credentials. Unterstützt: JPEG, PNG, WebP, GIF, WAV, MP4. Andere lokale Formate
  werden vor Submission abgelehnt. Die übernommenen Resultate landen im Projekt.
- `/estimate/{model_id}` erhält den tatsächlichen Request mit den referenzierten
  Snapshot-Medien. USD wird über den vorhandenen EUR-Kostenpfad normalisiert; steigt
  die Schätzung über die Freigabe, stoppt die Submission. 403 wird als Guthaben-/Zugangs-
  fehler behandelt, nicht pauschal als ungültiger Schlüssel.
- Eine Schätzung ist kein nachgewiesener Rechnungsbetrag. Bis ein verifizierter
  Abrechnungsendpunkt verfügbar ist, bleibt sie als Budgetreservierung bestehen;
  die Integration schreibt keine erfundene tatsächliche Belastung.

[Requests](https://docs.higgsfield.ai/docs/concepts/requests),
[Polling](https://docs.higgsfield.ai/docs/concepts/polling),
[Uploads](https://docs.higgsfield.ai/docs/concepts/file-uploads),
[Fehler](https://docs.higgsfield.ai/docs/concepts/errors),
[Kosten/Aufbewahrung](https://docs.higgsfield.ai/docs/concepts/billing-and-retention).

## Verifikation

Live geprüft: öffentliche Modellliste und Console-Schemas HTTP 200; nicht
authentifizierter Estimate liefert HTTP 401 `Invalid credentials`. Frühere Abrufe
mit Python-Standard-User-Agent lieferten vorgeschaltetes 403/1010; dies war kein
Nachweis über API-Credentials oder Modellzugang.

`HiggsfieldClientTests` und `HiggsfieldMappingTests` prüfen mit injizierten
HTTP-Fixtures Auth, Upload-Header, Pagination, Polling-Endzustände, Cancel,
Submission ohne Wiederholung, Modellparameter und getrennte API-/MCP-Kataloge.
Builds und Tests laufen ausschließlich in GitHub Actions auf `xcode-27`.

Offen: Mit lokal sicher hinterlegten API-Credentials echte Estimates/Uploads und
separat freigegebene gültige Generierungen für Bild, Frames, Referenzen, Edit und
Extend durchführen; Output, Projekt-Lineage und Kosten mit dem Anbieter vergleichen.
Keine absichtlich ungültigen kostenpflichtigen Generierungsproben.
