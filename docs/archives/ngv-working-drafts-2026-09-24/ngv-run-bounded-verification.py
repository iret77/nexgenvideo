import subprocess,time,json,shlex
from pathlib import Path
root=Path('<local NexGenVideo checkout>');out=root/'docs/ui/review/acceptance-2026-09-20'
prompt='''MULTIMODEL_REVIEW_LEAF_V1
Du bist Leaf-Reviewer. Keine Agents, Delegation, CLI-Aufrufe, Tools oder Änderungen. Antworte nur im übergebenen JSON-Schema. Eng begrenzte abschließende Prüfung der unten vollständig mitgelieferten Korrekturen eines statischen NexGenVideo-Clickdummys. Keine native App, Live-KI oder tatsächliche Abrechnung; nur UI-/Interaktionssimulation. Der vorige zusätzliche Repo-read-Prozess wurde vor Ergebnis durch SIGTERM beendet (kein Auth-/Policyfehler, nicht 900s); dies ist der einzige begrenzte Wiederanlauf, keine neue Gesamtprüfung.

Nur verbleibende HIGH/MEDIUM-Defekte mit konkret reproduzierbarem Ablauf. Keine stilistischen Vorschlagslisten. Unklare externe Funktionsverträge nicht erraten; fehlenden Kontext als Grenze benennen. Prüfe besonders: mehrere Revisionen dürfen bezahlte Takes und Signaturen nicht verwechseln; neue/geteilte Shots dürfen Clay-Szene nicht löschen; Zustandsreview in Story-Zeit darf keine falschen Shots korrigieren; Teil-Ankerlauf darf keine Phantom-Bilder zeigen; gemeinsame Animatic-Zeitachse darf nicht verfälschen. State ist S, clone ist JSON deep copy, changed erhöht version, isEdit erlaubt Mutation nur in aktueller unfreigegebener Phase. Workflow-Modul wird zuletzt vor dem ersten Render geladen; alte Funktionen werden über workflowBase aufgerufen. Bilder, 120-BPM-Ton und Kosten sind ausdrücklich Beispiele. Unveränderte native Verträge bleiben gesperrt. Wiederverwendung im Dummy vergleicht Inputs; sie beweist keine native exact-byte Lineage.

Die Browserprüfungen decken 237 Szenarien ab, darunter mehrfaches Rendern/Rewind, Teilanker+Stop+Undo, Splitkameras, neue und gelöschte Shots, Reviewkorrektur nur an Zielshot, Bildbefund trotz gewählter Ausnahme, Zeitachsen/Trackende und vollständigen Übergang in Schnitt. Keine Freigabe daraus ableiten; unabhängig denken. Prüfe den gelieferten Code, nicht den inzwischen überholten ersten Fable-Stand.''' 
for name in ['workflow','clay']:
 p=root/('docs/ui/desktop-production-workbench.'+name+'.js');content=p.read_text()
 if name=='clay':content='\n'.join(content.splitlines()[:28]+content.splitlines()[69:105]+content.splitlines()[-9:])
 prompt+='\n\nFILE '+str(p.relative_to(root))+'\n```js\n'+content+'\n```'
p=root/'docs/ui/desktop-production-workbench.js';ls=p.read_text().splitlines();prompt+='\n\nCORE EXCERPTS\n```js\n'+'\n'.join(ls[50:74]+ls[225:246])+'\n```'
(out/'fable-bounded-prompt.txt').write_text(prompt)
args=['claude-high5','-p',prompt,'--model','fable','--effort','high','--output-format','json','--json-schema',Path('<local home>/.codex/skills/agentic-review/review.schema.json').read_text(),'--tools','','--disable-slash-commands','--no-session-persistence','--permission-mode','plan','--strict-mcp-config','--mcp-config','{"mcpServers":{}}']
start=time.time()
with (out/'fable-bounded-result.json').open('w') as stdout,(out/'fable-bounded-stderr.log').open('w') as stderr:
 try:r=subprocess.run(['bash','-ic',shlex.join(args)],stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,cwd=root,timeout=900);rc=r.returncode
 except subprocess.TimeoutExpired:rc=124
(out/'fable-bounded-invocation.json').write_text(json.dumps({'command':'claude-high5','model':'fable','effort':'high','tools':[],'permission_mode':'plan','elapsed_seconds':round(time.time()-start),'exit_code':rc},indent=2));print('Bounded Fable verification exit',rc,flush=True)
raise SystemExit(rc)
