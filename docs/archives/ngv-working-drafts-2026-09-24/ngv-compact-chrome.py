from pathlib import Path
root=Path('<local NexGenVideo checkout>/docs/ui')
p=root/'desktop-production-workbench.fragment.html'
p.write_text(p.read_text().replace('  <div class="app-toolbar" id="nd-tools"></div>\n',''))
p=root/'desktop-production-workbench.js'
s=p.read_text();start=s.index('function chrome(){');end=s.index('\nconst mediaTypes',start)
s=s[:start]+'''function chrome(){
 $('#nd-title').innerHTML=`<div class="title-leading"><div class="lights" aria-hidden="true"><i></i><i></i><i></i></div>${panelButton('sidebar','panel-left')}<button type="button" class="project-title" data-do="project" aria-label="Projektmenü: ${E(S.name)}" data-tooltip="Projektmenü" data-tooltip-placement="bottom" ${S.running?'disabled':''}><span>${E(S.name)}</span><span aria-hidden="true">⌄</span></button><button type="button" class="chrome-icon undo-icon" data-do="undo" aria-label="Rückgängig" data-tooltip="Rückgängig · ⌘Z" data-tooltip-placement="bottom" ${!undo.length||S.running?'disabled':''}><span aria-hidden="true">↶</span></button></div><div class="workspace-switch" aria-label="Arbeitsbereich">${[['production','Produktion'],['edit','Schnitt'],['finish','Finish']].map(([p,t])=>B('workspace:'+p,t,{attrs:`aria-pressed="${p==='production'?!['edit','finish'].includes(S.view):p===S.view}"`})).join('')}</div><div class="title-trailing"><span class="pack-badge">${S.pack==='Music Video'?'Music Video':'Core'}</span>${panelButton('inspector','panel-right')}</div>`;
 panelState();globalThis.lucide?.createIcons({attrs:{width:16,height:16,'stroke-width':1.5}});
}
''' + s[end:]
s=s.replace("b.dataset.tooltipPlacement=b.dataset.panel==='sidebar'?'bottom-start':'bottom-end';","b.dataset.tooltipPlacement='bottom';")
s=s.replace("if(e.target.closest('[data-panel]'))return;","if(e.target.closest('#nd-title'))return;")
p.write_text(s)
p=root/'desktop-production-workbench.css';s=p.read_text()
s=s.replace('#ngv-desk .app-toolbar .panel-toggle','#ngv-desk .titlebar .panel-toggle')
s+='''
#ngv-desk .titlebar{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr);gap:12px;min-height:42px;padding:5px 8px}
#ngv-desk .title-leading,#ngv-desk .title-trailing{display:flex;align-items:center;gap:7px;min-width:0}
#ngv-desk .title-leading .lights{flex:none;margin-right:3px}
#ngv-desk .title-trailing{justify-content:flex-end}
#ngv-desk .titlebar .project-title{justify-content:flex-start;gap:5px;min-width:0;max-width:220px;font-size:12px;padding:3px 2px;color:#e3e3e8}
#ngv-desk .project-title>span:first-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#ngv-desk .project-title>span:last-child{font-size:11px;color:#bfc0c8}
#ngv-desk .titlebar .chrome-icon{width:28px;height:28px;padding:0;flex:0 0 28px;color:#c7c8d0}
#ngv-desk .titlebar .chrome-icon:disabled{color:#73737e;background:transparent;opacity:1}
#ngv-desk .undo-icon span{font-size:20px;line-height:1}
@media(max-width:800px){#ngv-desk .titlebar{gap:6px}#ngv-desk .title-leading,#ngv-desk .title-trailing{gap:4px}#ngv-desk .title-leading .lights{display:none}#ngv-desk .workspace-switch button{padding:3px 10px}}
@media(max-width:650px){#ngv-desk .titlebar{grid-template-columns:minmax(0,1fr) auto;gap:5px}#ngv-desk .title-leading{grid-column:1;grid-row:1}#ngv-desk .title-trailing{grid-column:2;grid-row:1}#ngv-desk .workspace-switch{grid-column:1/-1;grid-row:2;justify-self:center}#ngv-desk .titlebar .project-title{max-width:200px}}
@media(pointer:coarse){#ngv-desk .titlebar .chrome-icon,#ngv-desk .titlebar .project-title{min-height:44px}#ngv-desk .titlebar .chrome-icon{width:44px;flex-basis:44px}}
'''
p.write_text(s)
p=root/'desktop-production-workbench.test.js';s=p.read_text()
s=s.replace(" assert('Direct panel icons remain available with both panes hidden',all('.panel-toggle').length===2&&!q('.layout-menu'));\n",'')
needle="panel('inspector',false);assert('Both sides can independently be hidden',!visible('#nd-browser')&&!visible('#nd-inspector'));"
s=s.replace(needle,needle+"\n assert('Direct panel icons remain visible with both panes hidden',all('.panel-toggle').length===2&&all('.panel-toggle').every(b=>b.getBoundingClientRect().width>=28&&getComputedStyle(b).visibility==='visible')&&!q('.layout-menu'));\n assert('Window commands occupy only the titlebar',!q('#nd-tools')&&q('#nd-title [data-do=project]')&&q('#nd-title [data-do=undo]'));")
p.write_text(s)
