from pathlib import Path
p=Path('docs/ui/desktop-production-workbench.studio.js');s=p.read_text()
s=s.replace("const exposure=c.bypass", "const aspect=S.studio.aspect.split(':').map(Number);const exposure=c.bypass")
s=s.replace('style="aspect-ratio:${S.studio.aspect.replace', 'style="max-width:${aspect[0]/aspect[1]*(S.studio.theater?640:370)}px;aspect-ratio:${S.studio.aspect.replace')
s=s.replace("return before.value+(after.value-before.value)*Math.max(0,Math.min(1,(t-before.time)/(after.time-before.time)));", "let u=Math.max(0,Math.min(1,(t-before.time)/(after.time-before.time)));if(before.interpolation==='Ease In')u*=u;else if(before.interpolation==='Ease Out')u=1-(1-u)**2;else if(before.interpolation==='Ease In/Out')u=u*u*(3-2*u);return before.value+(after.value-before.value)*u;")
s=s.replace("if(S.running&&!['task-close','modal-close','activity','batch-stop','batch-resume'].includes(command))", "if(S.running&&!['modal-close','activity','batch-stop'].includes(command))")
s=s.replace("revision:S.version,clip:S.nle.selected,input:'',id:Date.now()", "revision:S.version,context:finishDigest(),clip:S.nle.selected,input:'',id:Date.now()")
s=s.replace("t.revision!==S.version||S.cost+", "t.revision!==S.version||t.context!==finishDigest()||S.cost+")
s=s.replace("q.revision!==S.version||S.cost+", "q.revision!==S.version||q.context!==finishDigest()||S.cost+")
# Completion must be checked before the next-item budget check.
s=s.replace("if(q.revision!==S.version||S.cost+.4>S.cap){S.running=false;q.stage='paused';render();return;}const i=q.targets[q.completed||0];", "const i=q.targets[q.completed||0];")
s=s.replace("S.takes[i]??=[];if(!S.takes[i].length)", "if(q.revision!==S.version||S.cost+.4>S.cap){S.running=false;q.stage='paused';render();return;}S.takes[i]??=[];if(!S.takes[i].length)")
s=s.replace("q.options[selected[0]]==='Ausgewählte Instanz ersetzen'", "q.options.some((x,i)=>x==='Ausgewählte Instanz ersetzen'&&selected.includes(i))")
s=s.replace("<input type=\"checkbox\" data-task-option=", "<input type=\"${['ai','repair','music','entity'].includes(t.kind)?'radio':'checkbox'}\" name=\"task-choice\" data-task-option=")
s=s.replace("q.selected=q.selected.filter(x=>x!==i);if(e.target.checked)","q.selected=e.target.type==='radio'?[]:q.selected.filter(x=>x!==i);if(e.target.checked)")
s=s.replace("selected:[],stage:'prepare'", "selected:options.length?[0]:[],stage:'prepare'")
# Remember explicit review decisions for the current image/sequence rather than merely logging the action.
s=s.replace("if(q.kind==='model')t.modelEvidence=true;", "if(q.kind==='model')t.modelEvidence=true;if(q.kind==='frameReview')t.frameReview={revision:S.version,entity:t.entity,checks:selected.map(i=>q.options[i])};")
s=s.replace("q.stage='review';q.cost", "q.stage='review';q.context=finishDigest();q.cost")
# Prevent physically clicking a just-edited text field from replacing the action underneath the pointer.
s=s.replace("studioSet(key,value);const selection=el.selectionStart;render();", "studioSet(key,value);if(el.type==='text'){const b=$('[data-do=\"studio:intake-add\"]');if(b)b.disabled=!S.studio.intakeName?.trim()||!S.studio.intakeAsset;persist();return;}const selection=el.selectionStart;render();")
# Running jobs and locked tracks expose their state on the inspector controls.
s=s.replace("if(S.running)$$('button", "if(S.nle.tracks.find(t=>t.id===nleClip()?.track)?.lock)$$('[data-sx^=\"clip-\"],[data-grade],[data-sx^=\"fx-\"],[data-sx^=\"curve-\"]').forEach(el=>el.disabled=true);if(S.running)$$('button")
# A muted audio lane uses audio vocabulary and icons.
s=s.replace("t.hidden?'eye-off':'eye','Spur '+t.id+' ein-/ausblenden'", "t.type==='audio'?(t.hidden?'volume-x':'volume-2'):(t.hidden?'eye-off':'eye'),'Spur '+t.id+(t.type==='audio'?' stummschalten':' ein-/ausblenden')")
# Accurate sample settings and no zero-speed state through numeric inputs.
s=s.replace("if(el.type==='number'&&!Number.isFinite(value))return;", "if(el.type==='number'&&(!Number.isFinite(value)||!el.validity.valid))return;")
s=s.replace("type==='checkbox'?el.checked:el.type==='number'?Number(el.value)", "type==='checkbox'?el.checked:['number','range'].includes(el.type)?Number(el.value)")
# Generation slots are governed by the selected demo capability profile.
a=s.index("generationDialog=function(){const result=oldGenerationDialog();")
b=s.index("const oldGenerationReady=",a)
s=s[:a]+'''generationDialog=function(){const result=oldGenerationDialog(),g=S.generation,m=generationModel();if(S.modal==='gen-cost'&&generationQuote)result.body+=group('Gebundene Quellen',prop('Eingabemodus',S.studio.generationMode||'Modellstandard')+prop('Endbild',assets().find(a=>a.id===S.studio.generationEnd)?.name||'Keines')+prop('Videoquelle',assets().find(a=>a.id===S.studio.generationSource)?.name||'Keine'),false);if(S.modal==='gen-form'&&m){const video=g.type==='video',flex=m.id.includes('seedance');result.body+=group('Eingaben & Ausgabe',video?sxSelect('Eingabemodus','generationMode',S.studio.generationMode||'Modellstandard',flex?['Modellstandard','Start / Ende','Referenzen','Quellvideo']:['Modellstandard'])+(flex?sxSelect(S.studio.generationMode==='Referenzen'?'Bildreferenz':'Endbild','generationEnd',S.studio.generationEnd||'',[['','Nicht verwenden'],...generationReferences().map(a=>[a.id,a.name])])+sxSelect('Quellvideo','generationSource',S.studio.generationSource||'',[['','Nicht verwenden'],...assets().filter(a=>a.type==='video'&&!a.offline).map(a=>[a.id,a.name])])+sxCheck('Getrimmte Quelle verwenden','generationTrim',S.studio.generationTrim):''):'<small>Dieses Demo-Profil hat keine weiteren Eingabeslots.</small>',false);}return result;};
''' +s[b:]
s=s.replace("const oldGenerationReady=generationReady;", "")
# Recreate quote when an input role changes; never combine a source-video mode and explicit frame mode.
s=s.replace("if(key.startsWith('generation')||key.startsWith('provider-')", "if(key==='generationMode'){t.generationEnd='';t.generationSource='';}if(key==='generationEnd')t.generationSource='';if(key==='generationSource')t.generationEnd='';\n if(key.startsWith('generation')||key.startsWith('provider-')")
p.write_text(s)
# Mode changes clear obsolete reference roles.
p=Path('docs/ui/desktop-production-workbench.generate.js');s=p.read_text().replace("const m=generationModel();if(m.durations", "const m=generationModel();if(S.studio&&!m.id.includes('seedance')){S.studio.generationMode='Modellstandard';S.studio.generationEnd='';S.studio.generationSource='';}if(m.durations");p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.studio.css');s=p.read_text()+'''\n@media(max-width:400px){#ngv-desk .workspace-switch{flex-wrap:wrap}#ngv-desk .statusbar{flex-wrap:wrap}#ngv-desk .statusbar label{min-width:0}#ngv-desk .studio-dialog .property{grid-template-columns:1fr}#ngv-desk .dialog-actions{flex-wrap:wrap}#ngv-desk .nle-toolbar{flex-wrap:wrap}}\n''';p.write_text(s)
