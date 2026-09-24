from pathlib import Path
p=Path('docs/ui/desktop-production-workbench.js');s=p.read_text()
s=s.replace('schema:5,workspaceMemory:', 'schema:6,sidebarVisible:true,workspaceMemory:')
s=s.replace('focus:false,inspector:true,left:166', 'inspector:true,left:200')
s=s.replace('version:5,workspace:', 'version:6,workspace:')
a=s.index(" $('#nd-tools').innerHTML=");b=s.index('\n}',a)
s=s[:a]+''' $('#nd-tools').innerHTML=B('project','Projekt ▾',{disabled:S.running})+`<span class="project-name">${E(S.name)}</span><span class="toolbar-separator" aria-hidden="true"></span>`+B('undo','↶ Rückgängig',{disabled:!undo.length||S.running})+`<span class="grow"></span><details class="layout-menu"><summary>Ansicht</summary><div class="layout-options"><strong>Bereiche einblenden</strong><label><input type="checkbox" data-panel="sidebar" ${S.sidebarVisible?'checked':''} aria-controls="nd-browser">Seitenleiste links</label><label><input type="checkbox" data-panel="inspector" ${S.inspector?'checked':''} aria-controls="nd-inspector">Inspector rechts</label></div></details>`;
''' +s[b:]
a=s.index(" if(workspace()==='edit')html=");b=s.index('\n}\nfunction mediaInspector',a)
s=s[:a]+''' if(workspace()==='edit')html=`<div class="group-label">SEQUENZEN</div>${B('sequence','Sequenz 01',{cls:'tree-row',attrs:`aria-pressed="${!S.mediaPreview}"`})}${pool()}`;
 else if(workspace()==='finish'&&!S.mediaOpen)html=`<div class="group-label">MASTER</div>${B('finish-section:review','Endkontrolle',{cls:'tree-row',attrs:`aria-pressed="${S.finishSection==='review'}"`})}${B('finish-section:delivery','Ausgabe',{cls:'tree-row',attrs:`aria-pressed="${S.finishSection==='delivery'}"`})}`;
 else if(S.mediaOpen)html=pool();
 else html=`<div class="workflow-heading">${S.pack==='Music Video'?'Music Video':'Core'}<small>Produktionsworkflow</small></div>${S.pack==='Music Video'?navrow('audio'):''}<div class="group-label">GESCHICHTE</div>${['brief','treatment','script'].map(navrow).join('')}<div class="group-label">SHOTS${S.shots.length?' · '+S.shots.length:''}</div>${['board','plan','refs','review'].map(navrow).join('')}<div class="group-label">GENERIERUNG</div>${navrow('takes')}<div class="library-count">${assets().length} Medien im Projekt<br><small>${sketchCount()} Sketches · ${Object.keys(S.takes).length} Shots mit Takes</small></div>`;
 const tabs=workspace()==='edit'?'':`<div class="sidebar-tabs" role="tablist" aria-label="Inhalt der Seitenleiste">${[['workflow',workspace()==='finish'?'Master':'Workflow'],['media','Medien']].map(([id,t])=>B('sidebar:'+id,t,{attrs:`id="nd-tab-${id}" role="tab" aria-controls="nd-sidebar-content" aria-selected="${S.mediaOpen===(id==='media')}"`})).join('')}</div>`;
 $('#nd-browser').innerHTML=tabs+`<div id="nd-sidebar-content" ${tabs?`role="tabpanel" aria-labelledby="nd-tab-${S.mediaOpen?'media':'workflow'}"`:''}>${html}</div>`;$('#nd-browser').classList.toggle('pool-browser',S.mediaOpen||workspace()==='edit');
''' +s[b:]
a=s.index('function render(){');b=s.index('\nfunction approve()',a)
s=s[:a]+'''function layout(){root.style.setProperty('--nd-left',S.left+'px');root.style.setProperty('--nd-right',S.right+'px');$('.desk-body').className='desk-body'+(!S.sidebarVisible?' hide-sidebar':'')+(!S.inspector?' hide-inspector':'');}
function render(){root.style.setProperty('--nd-accent',S.pack==='Music Video'?'#D940A0':'#636872');layout();chrome();browser();surfaceTools();canvas();bottom();inspector();gate();dialog();}
function undoContent(snapshot){const presentation={};for(const key of ['sidebarVisible','inspector','left','right','view','mode','selected','position','moment','mediaOpen','mediaFilter','mediaSelection','mediaPreview','workspaceMemory','productionView','finishSection'])presentation[key]=S[key];S={...snapshot,...presentation};}
''' +s[b:]
s=s.replace(" if(verb==='asset'){", " if(verb==='sidebar'){S.mediaOpen=param==='media';browser();persist();return;}\n if(verb==='asset'){")
s=s.replace("['stop-job','inspector','focus','budget','close']", "['stop-job','budget','close']")
s=s.replace(" case'media':stop();S.mediaOpen=!S.mediaOpen;S.mediaPreview=false;render();persist();break;\n", '')
s=s.replace("case'sketch-source':S.mediaOpen=true;", "case'sketch-source':S.sidebarVisible=true;S.mediaOpen=true;")
s=s.replace("redo.push(clone(S));S=undo.pop();", "redo.push(clone(S));undoContent(undo.pop());")
s=s.replace("undo.push(clone(S));S=redo.pop();", "undo.push(clone(S));undoContent(redo.pop());")
s=s.replace(" case'focus':S.focus=!S.focus;render();persist();break;\n case'inspector':S.inspector=!S.inspector;S.focus=false;render();persist();break;\n", '')
s=s.replace("root.addEventListener('change',e=>{", "root.addEventListener('change',e=>{if(e.target.dataset.panel){if(e.target.dataset.panel==='sidebar')S.sidebarVisible=e.target.checked;else S.inspector=e.target.checked;layout();persist();return;}")
s=s.replace("if(e.key==='Escape'&&S.focus){action('focus');}", '')
s=s.replace("if(e.key==='Escape'&&context)", "if(e.target.closest('.layout-menu')){if(e.key==='Escape'){$('.layout-menu').open=false;$('.layout-menu summary').focus();e.preventDefault();}return;}if(e.target.closest('.sidebar-tabs')&&['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();const other=e.target.dataset.do==='sidebar:media'?'workflow':'media';action('sidebar:'+other);$('[data-do=\"sidebar:'+other+'\"]').focus();return;}if(e.key==='Escape'&&context)")
s=s.replace("root.addEventListener('pointerdown',e=>{if(context", "root.addEventListener('pointerdown',e=>{if(!e.target.closest('.layout-menu')){const menu=$('.layout-menu');if(menu)menu.open=false;}if(context")
s=s.replace("![4,5].includes(saved?.schema)", "![4,5,6].includes(saved?.schema)")
s=s.replace("...saved,schema:5,playing:false,running:false,modal:null};", "...saved,schema:6,playing:false,running:false,modal:null};delete S.focus;if(saved.schema<6){S.sidebarVisible=true;S.inspector=true;S.left=Math.max(200,S.left);}if(S.view==='edit')S.mediaOpen=true;")
s=s.replace("columns:'2',inspector:true,height:850", "columns:'2',height:850")
s=s.replace("S.inspector=options.inspector;$('.desk-body').className='desk-body'+(!S.inspector?' hide-inspector':'');", '')
s=s.replace("tweak.addToggle(options,'inspector',{label:'Inspector sichtbar'});", '')
p.write_text(s)
# Remove the old focus layout; visibility is independent in every width.
p=Path('docs/ui/desktop-production-workbench.css');s=p.read_text()
import re
s=re.sub(r'#ngv-desk \.focus-mode[^{}]*\{[^{}]*\}', '', s)
s+='''
#ngv-desk .toolbar-separator{width:1px;height:20px;background:#42444b;margin:0 7px}
#ngv-desk .layout-menu{position:relative;z-index:12;margin-left:auto;font-size:13px}
#ngv-desk .layout-menu>summary{cursor:pointer;list-style:none;border-radius:4px;padding:5px 10px;background:#34363c;min-height:28px}
#ngv-desk .layout-menu>summary::after{content:' ▾'}
#ngv-desk .layout-menu>summary::-webkit-details-marker{display:none}
#ngv-desk .layout-options{position:absolute;right:0;top:34px;width:230px;padding:9px;background:#303239;border:1px solid #5a5c65;border-radius:5px;box-shadow:0 10px 30px #0008;display:flex;flex-direction:column;gap:5px}
#ngv-desk .layout-options>strong{font-size:11px;font-weight:500;color:#bcbfc8;padding:4px 6px}
#ngv-desk .layout-options label{display:flex;align-items:center;gap:10px;min-height:32px;padding:5px 6px;cursor:pointer}
#ngv-desk .layout-options label:hover{background:#40434b;border-radius:3px}
#ngv-desk .layout-options input{margin:0;flex:none}
#ngv-desk #nd-sidebar-content{display:flex;flex-direction:column;gap:2px;flex:1;min-width:0}
#ngv-desk .sidebar-tabs{display:flex;flex-shrink:0;gap:2px;padding:0 0 8px;position:sticky;top:-10px;background:#232429;z-index:2}
#ngv-desk .sidebar-tabs button{flex:1;font-size:12px;padding:4px 6px;min-width:0}
#ngv-desk .sidebar-tabs button[aria-selected=true]{background:#464851;color:#fff}
#ngv-desk .desk-body.hide-sidebar{grid-template-columns:minmax(0,1fr) 5px var(--nd-right)}
#ngv-desk .desk-body.hide-sidebar nav,#ngv-desk .desk-body.hide-sidebar .left-divider{display:none}
#ngv-desk .desk-body.hide-inspector aside,#ngv-desk .desk-body.hide-inspector .right-divider{display:none}
#ngv-desk .desk-body.hide-sidebar.hide-inspector{grid-template-columns:minmax(0,1fr)}
@media(max-width:650px){#ngv-desk .desk-body.hide-sidebar{grid-template-columns:minmax(0,1fr);grid-template-rows:580px auto}#ngv-desk .desk-body.hide-sidebar main,#ngv-desk .desk-body.hide-sidebar aside{grid-column:1}#ngv-desk .desk-body.hide-sidebar.hide-inspector{grid-template-rows:650px}#ngv-desk .sidebar-tabs{top:-4px;flex-wrap:wrap}#ngv-desk .sidebar-tabs button{flex-basis:100%}#ngv-desk .toolbar-separator{margin:0 2px}}
@media(max-width:400px){#ngv-desk nav{display:flex;max-height:240px;min-height:195px}#ngv-desk .sidebar-tabs{flex-wrap:nowrap}#ngv-desk .sidebar-tabs button{flex-basis:auto}#ngv-desk .desk-body.hide-sidebar,#ngv-desk .desk-body.hide-sidebar.hide-inspector{display:flex}#ngv-desk .desk-body.hide-sidebar main{height:650px}}
'''
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.spec.html');s=p.read_text().replace('Verstellbare Panelbreiten, Fokusansicht, Tastatur,', 'Verstellbare Panelbreiten, unabhängige Sichtbarkeit beider Seitenleisten, Tastatur,')
s=s.replace('in Produktion und Finish über „Medien“ erreichbar,', 'in Produktion und Finish als Reiter „Medien“ der linken Sidebar erreichbar,')
s=s.replace('<li>Drei Hauptarbeitsräume', '<li>Fenstersteuerung: „Ansicht“ enthält zwei unabhängige Checkboxen für Seitenleiste links und Inspector rechts. Jede ändert ausschließlich die genannte Seite; das Menü bleibt für weitere Einstellungen offen. Kein Fokus-/Arbeitsraum-Schalter. Links sind Workflow / Medien beziehungsweise Master / Medien ausdrücklich benannte Reiter; erneutes Anklicken schließt keinen Bereich. Ein Wechsel dieser Reiter verändert weder die zentrale Arbeitsfläche noch den Inspector oder eine laufende Wiedergabe. Die Sidebar behält dabei ihre Breite. Rückgängig steht getrennt bei den Bearbeitungsaktionen und setzt keine Fensteranordnung zurück. Gespeicherte frühere Fokuszustände werden in eine sichtbare Standardansicht migriert.</li>\n<li>Drei Hauptarbeitsräume')
p.write_text(s)
