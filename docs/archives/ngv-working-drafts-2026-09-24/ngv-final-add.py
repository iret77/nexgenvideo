from pathlib import Path
p=Path('docs/ui/desktop-production-workbench.generate.js');s=p.read_text();s=s.replace("const generationModels=[", "const generationModels=[")
s=s.replace("let generationQuote=null;", "generationModels.push({id:'elevenlabs-tts-v3',name:'Sprache · NGV-Demoprofil',provider:'ElevenLabs',type:'audio',audioKind:'tts',cost:.08,durations:[5,10,20]},{id:'elevenlabs-music',name:'Musik · NGV-Demoprofil',provider:'ElevenLabs',type:'audio',audioKind:'music',cost:.12,durations:[10,20,30]});\nlet generationQuote=null;")
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.studio.js');s=p.read_text();s=s.replace("generationMode,end:S.studio", "generationMode,end:S.studio")
s=s.replace("lyrics:S.studio.generationLyrics});", "lyrics:S.studio.generationLyrics,instrumental:S.studio.generationInstrumental});")
s=s.replace("'<small>Dieses Demo-Profil hat keine weiteren Eingabeslots.</small>'", "m.audioKind==='tts'?sxSelect('Stimme','generationVoice',S.studio.generationVoice||'Demo-Stimme',['Demo-Stimme','Demo-Stimme 2']):m.audioKind==='music'?sxInput('Lyrics / Stil','generationLyrics',S.studio.generationLyrics||'')+sxCheck('Instrumental','generationInstrumental',S.studio.generationInstrumental):'<small>Dieses Demo-Profil hat keine weiteren Eingabeslots.</small>'")
# General application changes perform an observable mock-state change.
s=s.replace("projectSaved:null,settings", "projectSaved:null,recent:['Claude Mouse','Leeres Projekt'],settings")
s=s.replace("[S.name,'Leeres Projekt','Claude Mouse · Recovery'].map", "t.recent.map")
s=s.replace("t.index=true;S.notice='Vorgang simuliert';", "if(command==='recent-remove')t.recent.pop();if(command==='pack-update')t.packVersion='Update für Recovery verfügbar';if(command==='pack-remove')t.removedVersion=true;if(command==='cache-clear')t.cacheCleared=true;t.index=true;S.notice='Vorgang simuliert';")
s=s.replace("prop('Originalmedien',assets().length+' Einträge')", "prop('Originalmedien',assets().length+' Einträge')+prop('Cache',t.cacheCleared?'Leer':'Beispiel-Vorschaudaten')")
s=s.replace("'Unbenutzte Pack-Version entfernen',{cls:'control'}", "t.removedVersion?'Unbenutzte Version entfernt':'Unbenutzte Pack-Version entfernen',{cls:'control',disabled:t.removedVersion}")
s=s.replace("if(q.kind==='organize'){assets()", "if(q.kind==='organize'){assets()").replace("a.type==='audio'?'audio':a.type==='video'?'footage'", "a.type==='audio'?'sound':a.type==='video'?'footage'")
s=s.replace("S.cost+=q.cost||0;studioAudit", "if(['music','sfx'].includes(q.kind)){const a=S.mediaImports.at(-1);a.duration=c?nleLength(c):5;S.mediaSelection=a.id;S.mediaMarked=[a.id];}\n S.cost+=q.cost||0;studioAudit")
# Direct manipulation remains optional, not always-on chrome around the image.
s=s.replace("sxCheck('Horizontal spiegeln'", "sxCheck('Im Bild positionieren','canvasEdit',S.studio.canvasEdit)+sxCheck('Horizontal spiegeln'")
s=s.replace('class="studio-picture" style=', 'class="studio-picture ${S.studio.canvasEdit?\'studio-positioning\':\'\'}" data-picture-drag style=')
s=s.replace("${SXI('capture','camera'", "${SXI('zoom','zoom-in','Vorschau vergrößern / einpassen')}${SXI('capture','camera'")
s=s.replace("--clip-scale:${key('scale',c.scale)/100}", "--clip-scale:${key('scale',c.scale)/100*S.studio.viewerZoom}")
s=s.replace("if(command==='compare')", "if(command==='zoom'){t.viewerZoom=t.viewerZoom===1?1.5:1;canvas();paintIcons();return;}\n if(command==='compare')")
s += '''\nlet pictureDrag=null;
root.addEventListener('pointerdown',e=>{const el=e.target.closest('[data-picture-drag]'),c=nleClip();if(!el||!S.studio.canvasEdit||!c||S.running||S.nle.tracks.find(t=>t.id===c.track)?.lock)return;checkpoint();const b=el.getBoundingClientRect();pictureDrag={id:c.id,x:e.clientX,y:e.clientY,cx:c.x,cy:c.y,w:b.width,h:b.height};el.setPointerCapture(e.pointerId);e.preventDefault();});
root.addEventListener('pointermove',e=>{if(!pictureDrag)return;const d=pictureDrag,c=S.nle.clips.find(c=>c.id===d.id);c.x=Math.round(d.cx+(e.clientX-d.x)/d.w*100);c.y=Math.round(d.cy+(e.clientY-d.y)/d.h*100);const el=$('[data-picture-drag]');el.style.setProperty('--clip-x',c.x+'%');el.style.setProperty('--clip-y',c.y+'%');});
root.addEventListener('pointerup',()=>{if(!pictureDrag)return;pictureDrag=null;render();persist();});
'''
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.studio.css');p.write_text(p.read_text()+'\n#ngv-desk .studio-positioning{outline:1px dashed #aeb1b9;outline-offset:-1px;cursor:move}#ngv-desk .studio-positioning:after{content:"↔";position:absolute;left:48%;top:48%;color:white;pointer-events:none}\n')
p=Path('docs/ui/desktop-production-workbench.media.js');s=p.read_text().replace("production:'Produktion',finish:'Finish'", "production:'Produktion',post:'Postproduction',finish:'Export'");p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.js');s=p.read_text().replace("const isEdit=()=>!S.running&&", "const isEdit=()=>!S.running&&S.studio?.packAvailable!==false&&!!workflowPacks[S.pack]&&");s=s.replace("fixture('Schnitt');", "fixture('Postproduction');");p.write_text(s)
