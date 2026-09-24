from pathlib import Path
base=Path('docs/ui')
def load(name):return (base/('desktop-production-workbench.'+name)).read_text()
def save(name,s):(base/('desktop-production-workbench.'+name)).write_text(s)
def replace(s,a,b):
 assert a in s,a[:160]
 return s.replace(a,b)
s=load('studio.js')
s=replace(s,"${['in','out'].map(edge=>", "${(S.view==='edit'&&!track?.lock?['in','out']:[]).map(edge=>")
s=replace(s,"<div class=\"studio-tabs\">${[['basic','Basis'],['curves','Kurven'],['wheels','Farbräder'],['lut','LUT'],['effects','Effekte'],['key','Chroma-Key']].map(([id,t])=>SX('grade-'+id,t,{attrs:`aria-pressed=\"${p===id}\"`})).join('')}</div>","<div class=\"studio-tabs inspector-tabs\" role=\"group\" aria-label=\"Farbwerkzeuge\">${[['basic','Basis','sliders-horizontal'],['curves','Kurven','chart-spline'],['wheels','Farbräder','aperture'],['lut','LUT','table-2'],['effects','Effekte','sparkles'],['key','Chroma-Key','pipette']].map(([id,t,icon])=>SXI('grade-'+id,icon,t,p===id)).join('')}</div>")
s=replace(s,"p==='lut'?'LUT':'Bildkorrektur'", "p==='lut'?'LUT':p==='effects'?'Effekte':p==='key'?'Chroma-Key':'Bildkorrektur'")
a="<div class=\"studio-tabs\">${[['video','Video'],['adjust','Farbe'],['audio','Ton'],['titles','Titel'],['captions','Untertitel'],['ai','KI']].filter(([id])=>c.type!=='audio'||['audio','titles','captions'].includes(id)).map(([id,t])=>B('nle:tab-'+id,t,{attrs:`aria-pressed=\"${S.nle.tab===id}\"`})).join('')}</div>"
b="<div class=\"studio-tabs inspector-tabs\" role=\"group\" aria-label=\"Clip-Eigenschaften\">${[['video','Video','sliders-horizontal'],['adjust','Farbe','palette'],['audio','Ton','volume-2'],['titles','Titel','type'],['captions','Untertitel','captions'],['ai','KI-Bearbeitung','wand-sparkles']].filter(([id])=>c.type!=='audio'||['audio','titles','captions'].includes(id)).map(([id,t,icon])=>B('nle:tab-'+id,NI(icon),{cls:'nle-icon',attrs:`aria-label=\"${t}\" data-tooltip=\"${t}\" aria-pressed=\"${S.nle.tab===id}\"`})).join('')}</div>"
s=replace(s,a,b)
start=s.index('const oldLibraryCanvas=libraryCanvas;');end=s.index('const oldLibraryInspector',start);s=s[:start]+s[end:]
s=s.replace('<div class="group-label">POSTPRODUCTION</div>','<div class="pane-heading">Postproduction</div>').replace('<div class="group-label">EXPORT</div>','<div class="pane-heading">Export</div>')
a='<div class="group-label">SEQUENZ 01</div><div class="studio-clip-list">${S.nle.clips.map(c=>SX(\'clip-\'+c.id,`<span>${E(clipName(c))}</span><small>${c.track} · ${tc(c.start)}</small>`,{cls:\'tree-row\',attrs:`aria-pressed="${S.nle.selected===c.id}"`})).join(\'\')}</div>'
s=replace(s,a,'${S.studio.post===\'review\'?`<div class="group-label">SEQUENZ 01</div><div class="studio-clip-list">${S.nle.clips.filter(c=>c.type!==\'audio\').map(c=>SX(\'review-clip-\'+c.id,`<span>${E(clipName(c))}</span><small>${c.track} · ${tc(c.start)}</small>`,{cls:\'tree-row\',attrs:`aria-pressed="${studioVisualAt(S.finish.cursor)?.id===c.id}"`})).join(\'\')}</div>`:\'\'}')
s=replace(s,"if(command.startsWith('clip-')&&command!=='clip-menu')", "if(command.startsWith('review-clip-')){const clip=n.clips.find(x=>x.id===command.slice(12));if(clip){S.finish.mode='film';S.finish.cursor=clip.start;render();persist();}return;}\n if(command.startsWith('clip-')&&command!=='clip-menu')")
s=replace(s,"protectInspector();};", "protectInspector();layoutInspector();paintIcons();};")
pos=s.index('inspector=function()')
s=s[:pos]+'''function layoutInspector(){const panel=$('#nd-inspector'),header=panel.querySelector('.inspector-header');if(!header)return;const body=document.createElement('div');body.className='inspector-scroll';for(const child of [...panel.children])if(child!==header&&!child.classList.contains('inspector-tabs'))body.append(child);panel.append(body);for(const node of header.children)node.dataset.tooltip=node.textContent;}
''' +s[pos:]
s=replace(s,"if(['edit','post','finish'].includes(S.view))$('#nd-gate').hidden=true;", "if(['edit','post'].includes(S.view))$('#nd-gate').hidden=true;")
s=replace(s,"${S.view==='finish'&&!['album','preview'].includes(S.finishSection)?B('finish:export','Exportieren…',{primary:true,disabled:!finishReady()}):''}","")
s=replace(s,'<span>${E(clipName(c))}<small>${tc(c.start)}</small></span>','<span><b>${E(clipName(c))}</b><small class="mono">${tc(c.start)}</small></span>')
s=replace(s,"oldRender();if(!$('#nd-task'))", "oldRender();revealShotSelection();if(!$('#nd-task'))")
s=s.replace("const oldBottom=bottom;",'''let shownShotContext='';
function revealShotSelection(){const key=S.view+':'+S.mode+':'+S.selected.join(',');if(shownShotContext===key)return;shownShotContext=key;const tile=$('#nd-canvas .shot-tile[aria-pressed=true],#nd-canvas .plan-row[aria-pressed=true]'),canvas=$('#nd-canvas');if(!tile)return;const a=tile.getBoundingClientRect(),b=canvas.getBoundingClientRect();if(a.bottom>b.bottom)canvas.scrollTop+=a.bottom-b.bottom+12;else if(a.top<b.top)canvas.scrollTop+=a.top-b.top-12;}
const oldBottom=bottom;''')
save('studio.js',s)
s=load('finish.js');s=replace(s,"function finishGate(){}",'''function finishGate(){const el=$('#nd-gate');el.hidden=S.view!=='finish'||S.finishSection!=='delivery';el.innerHTML=el.hidden?'':`<div class="phase-state"><b>Ausgabe · ${E(finishFormatLabel())}</b><small>${S.finish.format==='video'?'Sequenzreview: '+finishLabel():S.finish.format==='xml'?'Timeline für andere Editoren':'Projektkopie mit Medien'}</small></div>${B('finish:export','Exportieren…',{primary:true,disabled:!finishReady()})}`;}''');save('finish.js',s)
s=load('media.js')
a='return `<label class="pool-search">${MI(\'search\')}<input type="search"'
b='return `<label class="pool-search">${MI(\'search\')}${workspace()===\'media\'?`<select class="search-scope" data-search-scope aria-label="Suchbereich">${[[\'files\',\'Dateiname\'],[\'moments\',\'Bildinhalt\'],[\'spoken\',\'Transkript\']].map(([id,t])=>`<option value="${id}" ${S.studio.search===id?\'selected\':\'\'}>${t}</option>`).join(\'\')}</select>`:\'\'}<input type="search"'
s=replace(s,a,b)
s=replace(s,'<strong>Medien</strong><span class="grow"></span><div class="media-actions"','<strong class="media-path" data-tooltip="${E(folderPath(S.mediaFolder).map(f=>f.name).join(\' / \')||\'Alle Projektmedien\')}">${S.mediaFolder===\'all\'?\'Medien\':E(folderPath(S.mediaFolder).at(-1)?.name||\'Medien\')}</strong><span class="grow"></span><div class="media-actions"')
s=replace(s,"${mediaTool('media-import','download','Medien importieren',S.running)}", "${mediaTool('studio:index','sliders-horizontal',S.studio.index?'Suchindex verwalten · bereit':'Suchindex verwalten · pausiert',S.running)}${mediaTool('media-import','download','Medien importieren',S.running)}")
a='<span class="grow"></span>${MB(\'view-list\',\'list\',\'Listenansicht\',S.mediaView===\'list\')}${MB(\'view-grid\',\'layout-grid\',\'Miniaturansicht\',S.mediaView===\'grid\')}</div><div class="library-path"><span>${path.length?E(path.map(f=>f.name).join(\' / \')):\'Alle Projektmedien\'}</span><span class="grow"></span><label>Sortieren '
b='<span class="grow"></span><label class="media-sort"><span class="sr-only">Sortieren</span>'
s=replace(s,a,b)
s=replace(s,"${MB('sort',S.mediaSortDescending?'arrow-up':'arrow-down','Sortierrichtung ändern')}</div>", "${MB('sort',S.mediaSortDescending?'arrow-up':'arrow-down','Sortierrichtung ändern')}${MB('view-list','list','Listenansicht',S.mediaView==='list')}${MB('view-grid','layout-grid','Miniaturansicht',S.mediaView==='grid')}</div>")
s += "\nroot.addEventListener('change',e=>{if(e.target.matches('[data-search-scope]')){S.studio.search=e.target.value;refreshPool();$('[data-search-scope]')?.focus({preventScroll:true});}});\n"
save('media.js',s)
s=load('js');s=replace(s,"active?.focus({preventScroll:true});persist();}","active?.focus({preventScroll:true});revealShotSelection();persist();}");save('js',s)
