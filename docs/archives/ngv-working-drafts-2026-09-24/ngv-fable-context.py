from pathlib import Path
p=Path('docs/ui')
def rep(s,a,b):
 assert a in s,a[:100]
 return s.replace(a,b)
def line(s,start,new):
 ls=s.splitlines();matches=[i for i,v in enumerate(ls) if v.startswith(start)];assert len(matches)==1,(start,matches);ls[matches[0]]=new;return '\n'.join(ls)+'\n'
f=p/'desktop-production-workbench.studio.js';s=f.read_text()
s=rep(s,"const clipEditable=", "const syncPair=()=>{const v=selectedClips().filter(c=>c.type!=='audio'),a=selectedClips().filter(c=>c.type==='audio');return v.length===1&&a.length===1?{video:v[0],audio:a[0]}:null;};\nconst clipEditable=")
s=rep(s,"clip:S.nle.selected,input:", "clip:S.nle.selected,shot:at(),entity:S.studio.entity,phase:S.view,input:")
s=rep(s,"if(tasks[command]){task(...tasks[command]);return;}", "if(tasks[command]){if(command==='audio-sync'&&!syncPair())return;task(...tasks[command]);const q=t.task;q.command=command;if(command==='audio-sync'){const pair=syncPair();q.clip=pair.video.id;q.audio=pair.audio.id;q.options=['Ton um +0,12 s verschieben'];q.selected=[0];q.detail=clipName(pair.audio)+' an '+clipName(pair.video)+' ausrichten · Beispielmessung';}if(command==='entity-edit'){q.options=q.options.filter(o=>!t.entities[q.entity].locked.includes(o.split(':')[0]));q.selected=q.options.length?[0]:[];}if(command==='music'&&c?.type==='audio'){q.title='Musik erzeugen';q.detail='Neue Musikvariante anhand der gewählten Stilrichtung.';}renderTask();return;}")
s=rep(s,"'Material: Matt'", "'Material: Rau'")
s=rep(s,"'frame-remix':['Anker remixen','frame','Ausgewählte References in einer neuen Variante kombinieren.',['Identität erhalten','Kamera erhalten']]", "'frame-remix':['Anker remixen','frame','Identität und Kamera bleiben gebunden.',['Neue Ankervariante']]")
s=s.replace("['ai','repair','music','entity']", "['ai','repair','music','entity','frame']")
s=rep(s,"if(command==='task-close')", "if(command==='task-recheck'){const cmd=t.task.command;if(cmd){t.task=null;studioAction(cmd);}else{t.task.stage='prepare';t.task.context=finishDigest();t.task.revision=S.version;renderTask();}return;}\n if(command==='task-close')")
s=rep(s,"function renderTask(){", "function taskBlock(t){return t.revision!==S.version?'Projektstand geändert':t.context!==finishDigest()?'Schnitt oder Quellen geändert':S.cost+(t.cost||0)>S.cap?'Budget reicht nicht aus':'';}\nfunction renderTask(){")
s=rep(s,"disabled:t.revision!==S.version||t.context!==finishDigest()||S.cost+(t.cost||0)>S.cap", "disabled:!!taskBlock(t)||!!t.error")
s=rep(s,"<small>${t.stage==='review'?'Vorschau · noch nicht angewendet'", "${t.stage==='review'&&(taskBlock(t)||t.error)?`<small role=\"status\">${E(t.error||taskBlock(t))}</small>${SX('task-recheck','Vorschlag neu prüfen',{cls:'control'})}`:''}<small>${t.stage==='review'?'Vorschau · noch nicht angewendet'")
s=rep(s,"return;checkpoint();const selected=q.selected.length?q.selected:[0];", "return;if(c&&['color','word','ai'].includes(q.kind)&&!clipEditable(c)||['captions','caption'].includes(q.kind)&&!titleEditable())return;if(['entity','frame','measure','blockout','performance','pov'].includes(q.kind)&&(S.current!==q.phase||S.done[q.phase]))return;checkpoint();const selected=q.selected;")
s=line(s," if(q.kind==='sync')", " if(q.kind==='sync'){const audio=S.nle.clips.find(c=>c.id===q.audio);if(!clipEditable(audio)||!selected.includes(0))return;audio.start+=.12;}")
s=rep(s,"a.origin='KI-Auftrag · Simulation';", "if(q.kind==='frame'){a.folder='anchors';a.shot=q.shot;a.role=q.options[selected[0]];S.shots[q.shot].anchorVariant=id;S.anchorAccepted=S.anchorAccepted.filter(i=>i!==q.shot);changed();}a.origin='KI-Auftrag · Simulation';")
s=rep(s,"S.nle.titles.push({text,start:i*3", "S.nle.titles.push({track:'V2',text,start:i*3")
s=line(s," if(q.kind==='entity')", " if(q.kind==='entity'){const e=t.entities[q.entity],option=q.options[selected[0]];if(!e||!option)return;const [key,value]=option.split(':').map(x=>x.trim());if(e.locked.includes(key)){q.error='Attribut inzwischen gesperrt';renderTask();return;}e.attributes[key]=value;S.anchorAccepted=[];changed();}")
s=rep(s,"SX('entity-edit','Änderung vorschlagen…',{cls:'control'})", "SX('entity-edit','Änderung vorschlagen…',{cls:'control',disabled:!isEdit()})")
s=rep(s,"<small>${source?'Quelle':S.studio.compare?'Bearbeitet':'Sequenz 01'}</small>", "${source||S.studio.compare?`<small>${source?'Quelle':'Bearbeitet'}</small>`:''}")
s=rep(s,"${SXI('zoom','zoom-in'", "<div class=\"nle-transport-buttons\">${SXI('zoom','zoom-in'")
s=rep(s,"S.studio.theater)}</div><div class=\"studio-viewer-note\">", "S.studio.theater)}</div></div><div class=\"studio-viewer-note\">")
# Menus stay anchored and nonmodal; sheets remain for actual document tasks.
s=rep(s,"function studioModal(title,body,actions=''){return", "function studioModal(title,body,actions=''){if(['studio-project','studio-clip-menu','studio-asset-menu'].includes(S.modal)){const b=root.getBoundingClientRect(),pos=S.studio.menuPoint||{x:80,y:42};return `<section class=\"dialog studio-popover\" role=\"menu\" aria-label=\"${E(title)}\" style=\"left:${Math.max(4,Math.min(pos.x,b.width-240))}px;top:${Math.max(4,Math.min(pos.y,b.height-350))}px\">${body}</section>`;}return")
s=rep(s," if(kind==='clip-menu')", " if(kind==='asset-menu'){title='Medium';body=`<div class=\"studio-menu\">${SX('asset-rename','Umbenennen…')}${B('pool:move','Verschieben…')}${SX('asset-path','Dateiort anzeigen')}${a?.offline?SX('asset-relink','Neu verknüpfen…'):''}${SX('asset-delete','Auswahl löschen…')}</div>`;}\n if(kind==='clip-menu')")
s=rep(s,"['asset-rename','asset-delete'", "['asset-rename','asset-delete'") if False else s
s=rep(s,"'mcp-add','asset-rename'", "'mcp-add','asset-menu','asset-rename'")
s=rep(s,"['range','Bereich auswählen…']].map", "['range','Bereich auswählen…']].filter(([id])=>S.view!=='post'||!montageActions.includes(id)).map")
s=rep(s,"if(command==='project'){studioAction('project');return;}", "if(command==='project'){const r=root.getBoundingClientRect(),b=$('[data-do=project]').getBoundingClientRect();S.studio.menuPoint={x:b.left-r.left,y:b.bottom-r.top};studioAction('project');return;}")
s=rep(s,"if(clip){e.preventDefault();nleSelect", "if(clip||asset){const b=root.getBoundingClientRect();S.studio.menuPoint={x:e.clientX-b.left,y:e.clientY-b.top};}if(clip){e.preventDefault();nleSelect")
s=rep(s,"studioAction('asset-rename');}});", "studioAction('asset-menu');}});")
s += "\nroot.addEventListener('pointerdown',e=>{if($('.studio-popover')&&!e.target.closest('.studio-popover')){S.modal=null;dialog();}});\n"
s += "root.addEventListener('keydown',e=>{const menu=e.target.closest('.studio-popover');if(!menu)return;const items=[...menu.querySelectorAll('button:not(:disabled)')],i=items.indexOf(document.activeElement);if(['ArrowDown','ArrowUp'].includes(e.key)){e.preventDefault();items[(i+(e.key==='ArrowDown'?1:items.length-1))%items.length]?.focus();}});\n"
s=rep(s,"body,actions);paintIcons();};", "body,actions);paintIcons();if($('.studio-popover'))requestAnimationFrame(()=>$('.studio-popover button')?.focus());};")
f.write_text(s)
f=p/'desktop-production-workbench.js';s=f.read_text()
s=line(s,'const tc=',"const tc=t=>{const rate=fps(),f=Math.floor(Math.max(0,t)*rate+.001);return [Math.floor(f/(rate*3600)),Math.floor(f/(rate*60))%60,Math.floor(f/rate)%60,f%rate].map(n=>String(n).padStart(2,'0')).join(':');};")
s=s.replace("tc(a).slice(0,5)","tc(a).slice(3,8)").replace("tc(b).slice(0,5)","tc(b).slice(3,8)")
s=rep(s,"${sketchPic(at())}${pic(at(),'reference')}<div class=\"compare-line\">", "${sketchPic(at())}${shot().anchorVariant?assetImage(assets().find(a=>a.id===shot().anchorVariant)):pic(at(),'reference')}<div class=\"compare-line\">")
s=rep(s,"height:850,example:S.fixture", "height:850,example:S.fixture,condition:'Bereit'")
s=rep(s,"let example=options.example;", "let example=options.example,condition=options.condition;")
s=rep(s,"root.style.setProperty('--nd-thumb',options.columns);", "if(condition!==options.condition){condition=options.condition;S.studio.ready=condition!=='Agent nicht bereit';S.studio.packAvailable=condition!=='Pack fehlt';const a=selectedAsset();if(a)S.studio.assetEdits[a.id]={...S.studio.assetEdits[a.id],offline:condition==='Medium offline'};render();}root.style.setProperty('--nd-thumb',options.columns);")
s=rep(s,"tweak.addSelect(options,'columns'", "tweak.addSelect(options,'condition',{label:'Testsituation',options:['Bereit','Medium offline','Agent nicht bereit','Pack fehlt']});tweak.addSelect(options,'columns'")
f.write_text(s)
f=p/'desktop-production-workbench.studio.js';s=f.read_text().replace('tc(i*2).slice(0,5)','tc(i*2).slice(3,8)');f.write_text(s)
f=p/'desktop-production-workbench.studio.css';s=f.read_text()+'''\n#ngv-desk .studio-popover{position:absolute;width:232px;max-width:calc(100% - 8px);padding:5px;z-index:20;background:#2a2b30;border:1px solid #55565e;box-shadow:0 8px 22px #0008}
#ngv-desk .studio-popover .studio-menu{display:flex;flex-direction:column;gap:0;margin:0}#ngv-desk .studio-popover button{justify-content:flex-start;background:transparent;border:0;width:100%}
#ngv-desk .studio-popover button:hover{background:var(--nd-selected)}
#ngv-desk .nle-title-clip[aria-pressed=true]{outline:1px solid white}
''';f.write_text(s)
f=p/'build-desktop-production-workbench.py';s=f.read_text();s=rep(s,"for token, name in", "for size in [11, 12, 13, 17]:\n    value = f'calc({size}px * var(--nd-ui-scale,1))'\n    css = css.replace(value, f'var(--nd-f{size})') + f'#ngv-desk{{--nd-f{size}:{value}}}'\nfor token, name in");f.write_text(s)
