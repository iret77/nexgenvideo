import hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
src=root/'docs/production-knowledge/ai-film-production-3.4'
dst=root/'Engine/Sources/NexGenEngine/Resources/ProductionKnowledge/archives'
dst.mkdir(parents=True,exist_ok=True)
read=lambda n:json.loads((src/n).read_text())
sha=lambda s:hashlib.sha256(s.encode()).hexdigest()
contracts={c['id']:c for c in read('application-contracts.json')}
sections=[s for p in sorted((src/'chapters').glob('*.json')) for s in json.loads(p.read_text())]
byid={s['id']:s for s in sections}
records=[]
def record(id,s,text,kind,title=None,start=None,end=None):
 c=contracts[s['applicationContract']]
 evidence=s['applicationContract'] in ['platforms','platform-ui','sources','agent-evaluation'] or s['source']['path'].endswith(('platforms-models.md','platform-ui-workflows.md','sources.md','agent-models.md'))
 records.append(dict(id=id,sectionID=s['id'],title=title or s['title'],kind=kind,text=text,sha256=sha(text),source=s['source'],startCharacter=start,endCharacter=end,applicationContract=c['id'],consumers=['get_production_knowledge'],intendedConsumers=c.get('runtimeConsumers',[]),disposition='dated-evidence-not-executable' if evidence else 'retrievable-guidance-under-current-contract'))
for s in sections:record(s['id'],s,s['contentMarkdown'],'section')
for u in read('units.json'):
 s=byid[u['entryID']];record(u['id'],s,s['contentMarkdown'][u['startCharacter']:u['endCharacter']],'unit',start=u['startCharacter'],end=u['endCharacter'])
medium=byid['style-control-229b9a58a150']
position=0
for line in medium['contentMarkdown'].splitlines(keepends=True):
 if line.startswith('| ') and not line.startswith('| Medium / era'):
  label=line.split('|')[1].strip()
  if label and not set(label)<=set('-: '):
   record('medium-'+sha(label)[:12],medium,line,'medium-row',label,start=position,end=position+len(line))
 position+=len(line)
for collection,field,kind in [('blueprints','completeRecipeMarkdown','blueprint'),('procedures','completeProcedureMarkdown','runbook'),('tables','completeTableMarkdown','table'),('templates','completeTemplateMarkdown','template')]:
 for item in read(collection+'.json'):
  s=byid[item['entryID']];record(item['id'],s,item[field],kind,item.get('name',item.get('title',s['title'])))
for p in sorted((src/'formats').glob('*.md')):
 text=p.read_text();records.append(dict(id='format-'+p.stem.replace('.','-'),sectionID='',title=p.name,kind='format-spec',text=text,sha256=sha(text),source=dict(kind='ngv-adaptation',archiveSHA256=read('inventory.json')['archiveSHA256'],path='formats/'+p.name,startLine=1,endLine=len(text.splitlines()),sha256=sha(text),localDocument='formats/'+p.name),startCharacter=None,endCharacter=None,applicationContract='format-specification',consumers=['get_production_knowledge'],intendedConsumers=[],disposition='format-specification-not-runtime-implementation'))
plans=read('retrieval-plans.json')
bundle=dict(schemaVersion='production-knowledge-archive.v1',sourceVersion='3.4',archiveSHA256=read('inventory.json')['archiveSHA256'],license=(src/'LICENSE.source.txt').read_text(),precedence='\n'.join(x['id']+': '+x['ngvApplication'] for x in read('precedence.json')['overrides']),records=records,techniques=plans['techniques'])
data=(json.dumps(bundle,ensure_ascii=False,indent=2)+'\n').encode();(dst/'ai-film-production-3.4.json').write_bytes(data)
(dst/'manifest.json').write_text(json.dumps(dict(schemaVersion='production-knowledge-archive-manifest.v1',sourceVersion='3.4',path='ai-film-production-3.4.json',sha256=hashlib.sha256(data).hexdigest()),indent=2)+'\n')
ledger=dict(sourceVersion='3.4',archiveSHA256=bundle['archiveSHA256'],status='Runtime retrieval available; behavioral migration and Actions acceptance remain incomplete',consumer='ProductionKnowledgeLoaderV1.loadArchive34 → ToolExecutor.getProductionKnowledge',records=[{k:v for k,v in r.items() if k not in ['text','source']} for r in records])
(src.parent/'ai-film-production-3.4-runtime-ledger.json').write_text(json.dumps(ledger,ensure_ascii=False,indent=2)+'\n')
print('Bundled records:',len(records),'sections:',len(sections))
