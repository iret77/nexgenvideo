from pathlib import Path
p=Path('docs/ui/desktop-production-workbench.js');s=p.read_text()
pos=s.index('function chrome(){')
s=s[:pos]+'''function panelButton(side,icon){return `<button class="panel-toggle" data-panel="${side}" type="button" aria-controls="${side==='sidebar'?'nd-browser':'nd-inspector'}"><i data-lucide="${icon}" aria-hidden="true"></i></button>`;}
function panelState(){for(const b of $$('[data-panel]')){const on=b.dataset.panel==='sidebar'?S.sidebarVisible:S.inspector,label=(b.dataset.panel==='sidebar'?'Linke Seitenleiste':'Inspector')+(on?' ausblenden':' einblenden');b.setAttribute('aria-pressed',String(on));b.setAttribute('aria-label',label);b.dataset.tooltip=label;b.dataset.tooltipPlacement=b.dataset.panel==='sidebar'?'bottom-start':'bottom-end';}}
''' +s[pos:]
a=s.index(" $('#nd-tools').innerHTML=");b=s.index('\n}',a)
s=s[:a]+''' $('#nd-tools').innerHTML=panelButton('sidebar','panel-left')+`<span class="toolbar-separator" aria-hidden="true"></span>`+B('project','Projekt ▾',{disabled:S.running})+`<span class="project-name">${E(S.name)}</span><span class="toolbar-separator" aria-hidden="true"></span>`+B('undo','↶ Rückgängig',{disabled:!undo.length||S.running})+`<span class="grow"></span>`+panelButton('inspector','panel-right');
 panelState();globalThis.lucide?.createIcons({attrs:{width:16,height:16,'stroke-width':1.5}});
''' +s[b:]
s=s.replace("if(!b||b.disabled)return;if(b.dataset.do)", "if(!b||b.disabled)return;if(b.dataset.panel){if(b.dataset.panel==='sidebar')S.sidebarVisible=!S.sidebarVisible;else S.inspector=!S.inspector;layout();panelState();persist();return;}if(b.dataset.do)")
s=s.replace("if(e.target.dataset.panel){if(e.target.dataset.panel==='sidebar')S.sidebarVisible=e.target.checked;else S.inspector=e.target.checked;layout();persist();return;}", '')
s=s.replace("if(e.target.closest('.layout-menu')){if(e.key==='Escape'){$('.layout-menu').open=false;$('.layout-menu summary').focus();e.preventDefault();}return;}", "if(e.target.closest('[data-panel]'))return;")
s=s.replace("if(!e.target.closest('.layout-menu')){const menu=$('.layout-menu');if(menu)menu.open=false;}", '')
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.css');s=p.read_text();import re
s=re.sub(r'#ngv-desk \.layout-(?:menu|options)[^{}]*\{[^{}]*\}', '', s)
s+='''
#ngv-desk .app-toolbar .panel-toggle{width:28px;height:28px;min-height:28px;flex:0 0 28px;padding:5px;border:0;border-radius:3px;background:transparent;color:#979ba5}
#ngv-desk .app-toolbar .panel-toggle[aria-pressed=true]{background:#383a40;color:#dedfe5}
#ngv-desk .app-toolbar .panel-toggle:hover{background:#45484f;color:#f1f2f5}
#ngv-desk .panel-toggle svg{width:16px;height:16px;stroke-width:1.5;display:block;flex:none}
#ngv-desk .panel-toggle i{width:16px;height:16px;display:block}
@media(pointer:coarse){#ngv-desk .app-toolbar .panel-toggle{width:44px;height:44px;min-height:44px;flex-basis:44px}}
'''
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.spec.html');s=p.read_text()
s=s.replace('„Ansicht“ enthält zwei unabhängige Checkboxen für Seitenleiste links und Inspector rechts. Jede ändert ausschließlich die genannte Seite; das Menü bleibt für weitere Einstellungen offen. Kein Fokus-/Arbeitsraum-Schalter.', 'Zwei kleine direkte Panel-Icons sitzen an den äußeren Enden der Werkzeugleiste: links das Symbol für die linke Sidebar, rechts das spiegelbildliche Symbol für den Inspector. 16 px Symbol in 28 px Klickfläche; neutral und zurückhaltend. Sichtbarkeit durch eine leichte graue Tönung und aria-pressed; Tooltip benennt Ein-/Ausblenden. Jeder Schalter ändert ausschließlich die genannte Seite und bleibt auch bei geschlossener Sidebar an derselben Stelle erreichbar. Kein Ansichtsdropdown und kein Fokus-/Arbeitsraum-Schalter.')
s=s.replace('<h3>Quellen und sichtbare Übernahmen</h3>', '<h3>Review vor Präsentation</h3><p>Jeder weitere UI-/UX-Vorschlag muss vor der Präsentation visuell gegen die Desktop-Vorbilder und interaktiv auf Verständlichkeit, Zustände und Nebenwirkungen geprüft werden. Befunde werden zuerst behoben. Automatisierte Prüfungen ergänzen dieses Review, ersetzen es aber nicht.</p>\n<h3>Quellen und sichtbare Übernahmen</h3>')
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.test.js');s=p.read_text()
s=s.replace("const panel=(name,visible)=>{q('.layout-menu').open=true;const el=q('[data-panel='+name+']');if(el.checked!==visible)el.click();};", "const panel=(name,visible)=>{const el=q('[data-panel='+name+']');if(el.getAttribute('aria-pressed')!==String(visible))el.click();};")
s=s.replace(" assert('View menu stays open while changing panel visibility',q('.layout-menu').open);\n q('.layout-menu summary').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert('Escape closes view menu without changing layout',!q('.layout-menu').open&&state().sidebarVisible&&state().inspector);", " assert('Direct panel icons remain available with both panes hidden',all('.panel-toggle').length===2&&!q('.layout-menu'));\n assert('Panel controls identify side and current action',q('[data-panel=sidebar]').getAttribute('aria-label')==='Linke Seitenleiste ausblenden'&&q('[data-panel=inspector]').getAttribute('aria-label')==='Inspector ausblenden');")
p.write_text(s)
