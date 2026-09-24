from pathlib import Path
p=Path('docs/ui/desktop-production-workbench.workflow.js');s=p.read_text()
s=s.replace('S.songSnap??=false;','S.songSnap??=false;S.animaticZoom??=32;')
s=s.replace("if(S.modal==='wf-review-fix')", "if(S.modal==='wf-sketch'){workflowDialog('Sketch erzeugen',`<p>${E(shot().id+' · '+shot().action)}</p><small>Draw-Style · Beispielkosten 0,01 €. Die Simulation verwendet ein illustratives Sketch-Motiv.</small>`,B('wf:sketch-create','Für 0,01 € erzeugen',{primary:true,disabled:!isEdit()||S.cost+.01>S.cap}));return;}\n if(S.modal==='wf-review-fix')")
s=s.replace("<p>Betroffene Shots: ${quote('anchor').ids.map(E).join(' · ')}</p>","<details class=\"wf-order-details\"><summary>${quote('anchor').ids.length} betroffene Shots</summary><p>${quote('anchor').ids.map(E).join(' · ')}</p></details>")
s=s.replace("if(S.view==='audio'&&S.audioReady)$('#nd-inspector')", "if(S.view==='board'&&shot()&&moments(at()).some(m=>!m.asset))$('#nd-inspector').insertAdjacentHTML('beforeend',group('Sketch',B('wf:sketch','Sketch erzeugen…',{primary:true,disabled:!isEdit()||!shot().action.trim()})+'<small>Handlung zuerst festlegen; Upload und Medienauswahl bleiben möglich.</small>'));if(S.view==='plan'&&shot())$('#nd-inspector').insertAdjacentHTML('beforeend',group('Zustände · Story-Welt',field('Reihenfolge','worldOrder',shot().worldOrder,'number')+field('Eingang','stateIn',shot().stateIn)+field('Ausgang','stateOut',shot().stateOut),false));if(S.view==='audio'&&S.audioReady)$('#nd-inspector')")
s=s.replace(" if(cmd==='audio-play')", """ if(cmd==='sketch'&&S.view==='board'&&isEdit()&&shot()?.action.trim()){S.modal='wf-sketch';dialog();return;}
 if(cmd==='sketch-create'&&S.modal==='wf-sketch'&&S.view==='board'&&isEdit()&&S.cost+.01<=S.cap){undo=[];redo=[];const m=moments(at()).find(m=>!m.asset);if(!m)return;m.asset='base';m.sourceArt=shot().art;S.cost+=.01;S.modal=null;changed();render();persist();return;}
 if(cmd==='zoom-in'||cmd==='zoom-out'){S.animaticZoom=Math.max(12,Math.min(96,S.animaticZoom*(cmd==='zoom-in'?1.5:1/1.5)));bottom();paintIcons();return;}
 if(cmd==='audio-play')""")
s=s.replace("if(S.audioPosition>=199){", "if(!S.audioLoop&&S.audioPosition>=end){S.audioPosition=end;")
s=s.replace("if(beat!==auditionBeat&&auditionContext?.state==='running')", "if(S.audioPosition<199&&beat!==auditionBeat&&auditionContext?.state==='running')")
a=s.index('sequence=function()');b=s.index('const workflowEditField',a)
s=s[:a]+'''sequence=function(){
 if(S.view!=='board'||S.mode!=='animatic'||!S.shots.length)return workflowBase.sequence();
 const scale=S.animaticZoom,duration=total(),width=duration*scale,music=S.pack==='Music Video',start=S.songOffset,end=start+duration;
 const lane=music?sections.filter(([,a,b])=>b>start&&a<end).map(([n,a,b])=>`<span style="left:${Math.max(0,a-start)*scale}px;width:${(Math.min(b,end)-Math.max(a,start))*scale}px">${E(n)}</span>`).join(''):'';
 return `<div class="sequence-dock"><div class="sequence-controls"><b class="meta">ANIMATIC</b>${B('play',NI(S.playing?'pause':'play'),{cls:'nle-icon',attrs:`aria-label="${S.playing?'Animatic anhalten':'Animatic abspielen'}"`})}<span class="grow"></span><span class="mono" id="nd-time">${tc(S.position)} / ${tc(duration)}</span>${WI('zoom-out','minus','Zeitachse verkleinern')}${WI('zoom-in','plus','Zeitachse vergrößern')}</div>${music?`<div class="wf-song-map"><label>Song ab <input data-wf="song-offset" type="number" min="0" max="198.5" value="${start}" step=".5" aria-label="Song-Ausschnitt beginnt bei Sekunde"> s</label><span>199 s · synthetisches Hörbeispiel</span>${B('wf:song-snap',NI('magnet'),{cls:'nle-icon',attrs:`aria-label="Shotdauer auf Beats runden" data-tooltip="Shotdauer auf Beats runden" aria-pressed="${S.songSnap}"`})}</div>`:''}<div class="wf-time-scroll"><div class="wf-time-content" style="width:${width}px">${music?`<div class="wf-song-lane" aria-label="Songabschnitte und Beats">${lane}${end>199?`<span class="wf-silence" style="left:${Math.max(0,199-start)*scale}px;width:${(end-199)*scale}px">Song endet · ohne Ton</span>`:''}<i style="width:${Math.min(duration,199-start)*scale}px;--wf-beat:${.5*scale}px;background-position:${-(start%.5)*scale}px 0"></i></div>`:''}<div class="sequence-lane">${S.shots.map((s,i)=>`<button data-shot="${i}" style="width:${s.duration*scale}px;flex:none" aria-pressed="${S.selected.includes(i)}" aria-label="${E(s.id+' · '+s.duration+' Sekunden')}">${E(s.id)}<small>${s.duration.toFixed(1)} s</small></button>`).join('')}</div><div class="playhead" style="--position:${100*S.position/duration}%"></div></div></div><input data-scrub type="range" min="0" max="${duration}" value="${S.position}" step="${1/fps()}" aria-label="Animatic-Zeitposition"></div>`;
};
''' +s[b:]
s=s.replace("Math.min(199-total(),Number(e.target.value)||0)","Math.min(198.5,Number(e.target.value)||0)")
s=s.replace("audioPaint();}});\n\nassetImage", "canvas();inspector();paintIcons();}});\n\nassetImage")
# Guard effective choices and keep the findings independent of human decisions.
s=s.replace("issue&&!S.takeNote?.trim()", "issue&&!(S.takeNote??r?.note)?.trim()",1)
s += '''\nconst workflowReason=reason;
reason=function(){if(S.view==='review'&&S.reviewRun&&continuityFindings().length)return continuityFindings().length+' Zustandsübergang prüfen';return workflowReason();};
const workflowBottom=bottom;
bottom=function(){const scroll=$('.wf-time-scroll')?.scrollLeft||0;workflowBottom();if($('.wf-time-scroll'))$('.wf-time-scroll').scrollLeft=scroll;};
position=function(t){workflowBase.position(t);const scroller=$('.wf-time-scroll');if(S.playing&&scroller){const x=S.position*S.animaticZoom;if(x<scroller.scrollLeft||x>scroller.scrollLeft+scroller.clientWidth-30)scroller.scrollLeft=Math.max(0,x-40);}};
'''
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.js');s=p.read_text()
a=s.index("const inp=s.id==='1E'");b=s.index("body=group('Eingang'",a)
s=s[:a]+"const inp=s.stateIn;const out=s.stateOut;"+s[b:]
s=s.replace('playing:false,running:false,mediaJob:null,modal:null','playing:false,audioRunning:false,running:false,mediaJob:null,modal:null')
# Existing field handler enforces the phase for other shot properties; new state controls share that path.
s=s.replace("if(['name','action'", "if(['worldOrder','stateIn','stateOut','name','action'")
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.workflow.css');s=p.read_text()+'''\n#ngv-desk .wf-time-scroll{overflow-x:auto;overflow-y:hidden;position:relative;margin:0 12px}
#ngv-desk .wf-time-content{position:relative;min-width:0}
#ngv-desk .wf-time-content .sequence-lane{overflow:visible;gap:0;padding:0;margin:0;height:54px;min-width:0}
#ngv-desk .wf-time-content .sequence-lane button{min-width:0;overflow:hidden;border-radius:0;border-right:1px solid var(--nd-line);box-sizing:border-box;padding:5px 4px}
#ngv-desk .wf-time-content .wf-song-lane{margin:0;height:26px;min-width:0;display:block}
#ngv-desk .wf-time-content .wf-song-lane>span{position:absolute;top:0;height:26px;box-sizing:border-box}
#ngv-desk .wf-time-content .wf-song-lane>i{right:auto}
#ngv-desk .wf-silence{color:var(--nd-muted);background:var(--nd-bg)}
#ngv-desk .wf-time-content>.playhead{position:absolute;top:0;bottom:0;left:var(--position);pointer-events:none}
#ngv-desk .wf-time-content .sequence-lane small{white-space:nowrap}
#ngv-desk .wf-take-choices{overflow-x:auto;flex-shrink:0}
''';p.write_text(s)
