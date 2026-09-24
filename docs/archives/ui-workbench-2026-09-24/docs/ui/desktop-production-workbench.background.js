let bgOpen='',bgAI=null,bgPreview='Keine',bgOwner=null,bgSummary='';
const bgNames={ai:'KI-Aktivität',export:'Exporte'};
const bgState={running:'In Arbeit',complete:'Abgeschlossen',cancelled:'Abgebrochen',paused:'Unterbrochen',failed:'Fehlgeschlagen'};
function bgStart(title,detail,stopCommand,total=null){bgAI={title,detail,stopCommand,total,done:0,status:'running'};}
function bgFinish(status,detail){if(bgAI){bgAI.status=status;if(detail)bgAI.detail=detail;}renderBackground();}
function bgJob(kind){
 if(kind==='ai'){if(bgAI)return bgAI;const t=S.studio.task;if(t?.stage==='paused')return {title:t.title,detail:'Fertige Takes bleiben erhalten',status:'paused',done:t.completed,total:t.targets.length};}
 if(kind==='export'){
  const f=S.finish,x=f?.exports.find(x=>x.id===f.job?.id)||f?.exports.at(-1);
  if(x){const j=f.job;return {title:x.name,detail:x.label+' · '+(j?['Sequenz vorbereiten','Videodatei schreiben','Ausgabe prüfen'][j.stage]:x.status==='complete'?'Ausgabe geprüft':bgState[x.status]),status:x.status,progress:j?.stage===1?j.progress:null,stopCommand:j?'finish:cancel':null,folder:x.folder};}
 }
 if(bgPreview.startsWith(kind==='ai'?'KI':'Export'))return {title:kind==='ai'?'Shot 1E · Continuity prüfen':'Claude Mouse · Master.mp4',detail:kind==='ai'?'Claude · Bildvorlagen mit Shotplan abgleichen':bgPreview==='Export fehlgeschlagen'?'Zielordner nicht erreichbar':'H.264 · 1920 × 1080 · Videodatei schreiben',status:bgPreview==='Export fehlgeschlagen'?'failed':'running',progress:kind==='export'&&bgPreview!=='Export fehlgeschlagen'?.46:null,sample:true};
 return null;
}
function bgButton(kind){const j=bgJob(kind),active=j?.status==='running',label=bgNames[kind]+': '+(j?bgState[j.status]:'Keine laufenden Aufträge'),p=j?.total?j.done/j.total:j?.progress;return B('background:'+kind,`<span class="bg-ring ${active?'busy':''} ${active&&p==null?'indeterminate':''}" style="--bg-turn:${Math.max(0,Math.min(1,p??.22))*360}deg">${NI(kind==='ai'?'sparkles':'arrow-up')}</span><span>${kind==='ai'?'KI':'Export'}</span>${j?.status==='failed'?'<span class="bg-error">!</span>':''}`,{cls:'bg-indicator',attrs:`aria-label="${E(label)}" data-tooltip="${E(label)}" aria-expanded="${bgOpen===kind}" aria-controls="nd-background" aria-haspopup="dialog" data-state="${j?.status||'idle'}"`});}
function renderBackground(){
 if(!S)return;if(bgOwner!==S){bgOwner=S;bgAI=null;bgOpen='';}
 const buttons=$('#nd-bg-buttons');if(!buttons)return;
 const focused=document.activeElement?.closest('[data-do^="background:"]')?.dataset.do;
 buttons.innerHTML=bgButton('ai')+bgButton('export');
 const summary=['ai','export'].map(k=>{const j=bgJob(k);return j?j.title+' · '+bgState[j.status]:'';}).filter(Boolean).join('. ');if(summary!==bgSummary){bgSummary=summary;$('#nd-announcement').textContent=summary;}
 const el=$('#nd-background');if(!el)return;el.hidden=!bgOpen;if(!bgOpen){el.innerHTML='';paintIcons();return;}
 const expanded=$('#nd-background details')?.open;const j=bgJob(bgOpen),running=j?.status==='running',progress=j?.total?j.done/j.total:j?.progress;
 el.setAttribute('aria-label',bgNames[bgOpen]);
 el.innerHTML=`<header><b>${bgNames[bgOpen]}</b><span class="grow"></span>${B('background:close','Schließen',{cls:'bg-close',attrs:'aria-label="Aktivitätsfenster schließen"'})}</header><div class="bg-content">${j?`<div class="bg-job"><div class="bg-job-title"><b>${E(j.title)}</b><span>${bgState[j.status]}</span></div><p>${E(j.detail)}</p>${running?`<progress max="1" ${progress==null?'':`value="${progress}"`} aria-label="${E(j.title)}: ${j.total?j.done+' von '+j.total+' fertig':progress==null?j.detail:Math.round(progress*100)+' Prozent'}"></progress>${progress==null?'':`<small>${j.total?j.done+' von '+j.total+' fertig':Math.round(progress*100)+' %'}</small>`}`:''}${j.items?`<details ${expanded?'open':''}><summary data-do="background:items">${j.items.length} Einzelaufträge</summary>${j.items.map((x,i)=>`<small>${E(x)} · ${i<j.done?'Fertig':i===j.done&&running?'In Arbeit':'Ausstehend'}</small>`).join('')}</details>`:''}${j.folder?`<small>${E(j.folder)}</small>`:''}${running&&j.stopCommand?B('background:stop','Abbrechen',{cls:'control'}):''}${j.sample?'<small>Beispielzustand · kein laufender Auftrag</small>':''}</div>`:`<p class="bg-empty">Keine laufenden ${bgOpen==='ai'?'KI-Aufträge':'Exporte'}.</p>`}</div>`;
 const trigger=$('[data-do="background:'+bgOpen+'"]'),r=root.getBoundingClientRect(),b=trigger.getBoundingClientRect();
 el.style.right=Math.min(Math.max(8,r.right-b.right),Math.max(8,r.width-el.offsetWidth-8))+'px';el.style.bottom=(r.bottom-$('#nd-status').getBoundingClientRect().top+8)+'px';
 paintIcons();if(focused)$('[data-do="'+focused+'"]')?.focus({preventScroll:true});
}
function bgClose(focus=false){const kind=bgOpen;bgOpen='';renderBackground();if(focus)$('[data-do="background:'+kind+'"]')?.focus({preventScroll:true});}
const bgAction=action;
action=function(command){
 if(!command.startsWith('background:')){bgAction(command);return;}
 const c=command.slice(11);
 if(c==='close'){bgClose(true);return;}
 if(c==='stop'){const j=bgJob(bgOpen);if(j?.status==='running'&&j.stopCommand){bgAction(j.stopCommand);renderBackground();$('#nd-background [data-do="background:close"]')?.focus();}return;}
 if(['ai','export'].includes(c)){if(S.modal)return;if(bgOpen===c){bgClose(true);return;}bgOpen=c;renderBackground();$('#nd-background [data-do="background:close"]')?.focus({preventScroll:true});}
};
root.addEventListener('pointerdown',e=>{if(bgOpen&&!e.target.closest('#nd-background,[data-do^="background:"]'))bgClose();},true);
root.addEventListener('keydown',e=>{if(!bgOpen)return;if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();bgClose(true);}else if(e.target.closest('#nd-background'))e.stopPropagation();},true);
root.addEventListener('focusin',e=>{if(bgOpen&&!e.target.closest('#nd-background,[data-do^="background:"]'))bgClose();});
const bgRender=render;
render=function(){bgRender();if(S.modal)bgOpen='';renderBackground();};

new ResizeObserver(()=>{if(bgOpen)renderBackground();}).observe(root);
