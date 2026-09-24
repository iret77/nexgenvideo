const NI=icon=>`<i data-lucide="${icon}" aria-hidden="true"></i>`;
const NB=(a,icon,label,disabled=false,pressed=null)=>B('nle:'+a,NI(icon),{disabled,cls:'nle-icon',attrs:`aria-label="${label}" data-tooltip="${label}" ${pressed===null?'':`aria-pressed="${pressed}"`}`});
function ensureNLE(){
 if(S.current==='edit'&&S.done.takes&&!S.have.edit){S.have.edit=true;if(!S.nle?.clips.length)S.nle=null;}
 if(S.view!=='edit'&&!S.have.edit)return;
 if(S.nle){let end=0;S.nle.clips.forEach(c=>{if(!Number.isFinite(c.start))c.start=end;end=c.start+(c.out-c.in)/c.speed;});S.nle.audioLength??=end;}
 if(!S.nle){const clips=(S.have.edit?(S.editOrder.length?S.editOrder:S.shots.map((_,i)=>i)):[]).filter(i=>S.shots[i]&&S.chosen[i]).map((i,k)=>({id:'clip-'+k,shot:i,take:S.chosen[i],in:0,out:S.shots[i].duration-(S.shots[i].trim||0),scale:100,x:0,y:0,opacity:100,speed:1,exposure:0,saturation:100}));let start=0;clips.forEach(c=>{c.start=start;start+=c.out-c.in;});S.nle={clips,audioLength:start,selected:clips[0]?.id||null,cursor:0,sourceCursor:0,tool:'pointer',zoom:1,tab:'video',hidden:false,muted:false,sync:true,gain:0,titles:[],height:296,nextId:clips.length};}
}
const nleClip=()=>S.nle?.clips.find(c=>c.id===S.nle.selected);
const nleLength=c=>(c.out-c.in)/c.speed;
const nleTotal=()=>S.nle?Math.max(S.nle.audioLength||0,...S.nle.clips.map(c=>c.start+nleLength(c)),...S.nle.titles.map(t=>t.end)):0;
const nleSpan=()=>Math.max(24,Math.ceil(nleTotal()/5)*5);
const nleStart=id=>S.nle.clips.find(c=>c.id===id)?.start||0;
const nleAt=t=>S.nle?.clips.find(c=>t>=nleStart(c.id)&&t<nleStart(c.id)+nleLength(c))||null;
const nleSource=()=>S.mediaPreview&&!!selectedAsset();
const nleDuration=()=>nleSource()?(assetDuration(selectedAsset())||5):nleTotal();
const nleCursor=()=>nleSource()?S.nle.sourceCursor:S.nle.cursor;
function nleTools(){const a=selectedAsset(),source=S.mediaPreview&&a,name=source?a.name:'Sequenz 01';return `<span class="nle-viewer-kind">${source?'Medienvorschau':'Filmvorschau'}</span><span class="nle-viewer-name" data-tooltip="${E(name)}">${E(name)}</span>`;}
function nleView(){}
function nleCanCut(){const c=nleClip(),t=S.nle.cursor;return isEdit()&&!S.mediaPreview&&c&&!S.nle.tracks.find(t=>t.id===c.track)?.lock&&t>c.start+1/48&&t<c.start+nleLength(c)-1/48;}
function nleTimeline(){}
function nleField(label,key,value,min,max,step=1){return `<label class="property"><span>${label}</span><input data-nle-field="${key}" type="number" min="${min}" max="${max}" step="${step}" value="${value}" ${isEdit()?'':'disabled'}></label>`;}
function nleInspector(){}
function nleSeek(){}
function nleSelect(){}
function nleChanged(message){const active=document.activeElement,command=active?.dataset.do,edge=active?.dataset.nleTrim;S.editOrder=S.nle.clips.map(c=>c.shot);S.finishCheck=false;S.notice=message;S.nle.cursor=Math.min(S.nle.cursor,nleSpan());render();const focus=command?$('[data-do="'+command+'"]'):edge?$('[data-clip-id="'+active.dataset.clipId+'"][data-nle-trim="'+edge+'"]'):$('[data-nle-clip="'+S.nle.selected+'"]');if(focus&&!focus.disabled)focus.focus({preventScroll:true});persist();}
function nleAction(command){
 if(!S.have.edit)return;ensureNLE();const n=S.nle,c=nleClip();
 if(command.startsWith('tab-')){n.tab=command.slice(4);S.mediaPreview=false;render();persist();return;}
 if(command==='original'){visit('takes');return;}
 if(command==='play'){
  if(S.mediaPreview&&selectedAsset()?.type!=='video')return;
  if(S.playing){stop();canvas();paintIcons();return;}if(nleCursor()>=nleDuration())nleSeek(0);S.playing=true;lastFrame=0;canvas();paintIcons();
  let playTime=nleCursor();const step=now=>{if(!S.playing)return;playTime+=lastFrame?(now-lastFrame)/1000:0;const t=playTime;lastFrame=now;if(t>=nleDuration()){nleSeek(nleDuration());stop();canvas();paintIcons();persist();return;}nleSeek(t);raf=requestAnimationFrame(step);};raf=requestAnimationFrame(step);return;
 }
 if(['start','prev','next','end'].includes(command)){if(S.mediaPreview&&selectedAsset()?.type!=='video')return;stop();nleSeek(command==='start'?0:command==='end'?nleDuration():nleCursor()+(command==='prev'?-1:1)/fps());bottom();paintIcons();persist();return;}
 if(command.startsWith('tool-')){if(command==='tool-razor'&&!isEdit())return;n.tool=command.slice(5);bottom();paintIcons();persist();return;}
 if(!isEdit())return;stop();
 if(command==='split'||command==='trim-in'||command==='trim-out'){
  const hit=nleClip();if(!hit||S.mediaPreview||S.nle.tracks.find(t=>t.id===hit.track)?.lock)return;const offset=(n.cursor-nleStart(hit.id))*hit.speed,cut=Math.round((hit.in+offset)*fps())/fps();if(cut<=hit.in+1/48||cut>=hit.out-1/48)return;
  checkpoint();if(command==='split'){const after={...clone(hit),id:'clip-'+n.nextId++,in:cut,start:n.cursor};hit.out=cut;n.clips.splice(n.clips.indexOf(hit)+1,0,after);n.selected=after.id;n.marked=[after.id];n.selectedTitle=null;S.selected=[after.shot];}else if(command==='trim-in'){hit.start+=(cut-hit.in)/hit.speed;hit.in=cut;}else hit.out=cut;nleChanged(command==='split'?'Clip geteilt':'Clip getrimmt');return;
 }
 if(command==='hide'||command==='mute'||command==='sync'){checkpoint();n[{hide:'hidden',mute:'muted',sync:'sync'}[command]]=!n[{hide:'hidden',mute:'muted',sync:'sync'}[command]];nleChanged(command==='sync'?(n.sync?'Sync-Lock aktiv':'Sync-Lock inaktiv'):command==='hide'?(n.hidden?'Videospur ausgeblendet':'Videospur sichtbar'):(n.muted?'Audiospur stumm':'Audiospur aktiv'));return;}

}
function nleEditField(el){if(!isEdit()||!S.nle)return;const c=nleClip(),key=el.dataset.nleField,value=+el.value;if(!Number.isFinite(value)||!c)return;const limits={in:[0,c.out-1/fps()],out:[c.in+1/fps(),frameDuration(c)],scale:[25,200],x:[-50,50],y:[-50,50],opacity:[0,100],speed:[.25,4],exposure:[-2,2],saturation:[0,200],gain:[-60,6]}[key];if(!limits)return;checkpoint();const v=Math.max(limits[0],Math.min(limits[1],value));if(key==='gain')S.nle.gain=v;else{const oldEnd=c.start+nleLength(c);if(key==='in')c.start+=(v-c.in)/c.speed;c[key]=['in','out'].includes(key)?Math.round(v*fps())/fps():v;if(key==='speed'){const delta=c.start+nleLength(c)-oldEnd;let tail=oldEnd;for(const after of S.nle.clips.slice(S.nle.clips.indexOf(c)+1)){if(Math.abs(after.start-tail)>1/48)break;tail=after.start+nleLength(after);after.start+=delta;}}}nleChanged('Clip-Einstellung geändert');$('[data-nle-field="'+key+'"]')?.focus({preventScroll:true});}
function paintIcons(){$$('button,summary').forEach(el=>el.classList.add('cursor-interaction'));globalThis.lucide?.createIcons({attrs:{width:16,height:16,'stroke-width':1.5}});}
let nleDrag=null;
root.addEventListener('input',e=>{if(e.target.matches('[data-nle-scrub]')){stop();const source=S.mediaPreview;S.mediaPreview=false;nleSeek(+e.target.value,false);if(source){surfaceTools();inspector();layout();paintIcons();}}if(e.target.matches('[data-nle-zoom]')){S.nle.zoom=+e.target.value;$('.nle-content').style.width=S.nle.zoom*100+'%';}});
root.addEventListener('change',e=>{if(e.target.dataset.nleField)nleEditField(e.target);if(e.target.matches('[data-nle-scrub],[data-nle-zoom]')){bottom();paintIcons();persist();}});
root.addEventListener('pointerdown',e=>{if(!e.target.matches('[data-nle-height]'))return;stop();e.preventDefault();e.target.setPointerCapture(e.pointerId);nleDrag={height:S.nle.height,y:e.clientY};});
root.addEventListener('pointermove',e=>{if(!nleDrag)return;S.nle.height=Math.max(245,Math.min(410,nleDrag.height+nleDrag.y-e.clientY));root.style.setProperty('--nle-height',S.nle.height+'px');});
root.addEventListener('pointerup',()=>{if(nleDrag){nleDrag=null;persist();}});
root.addEventListener('keydown',e=>{if(!['edit','post'].includes(S.view)||!S.have.edit||S.modal||e.target.closest('#nd-title,#nd-browser')||/INPUT|TEXTAREA|SELECT/.test(e.target.tagName))return;if(e.target.matches('[data-nle-height]')&&['ArrowUp','ArrowDown'].includes(e.key)){e.preventDefault();S.nle.height=Math.max(245,Math.min(410,S.nle.height+(e.key==='ArrowUp'?10:-10)));root.style.setProperty('--nle-height',S.nle.height+'px');persist();return;}const handle=e.target.closest('[data-nle-trim]');if(handle&&['ArrowLeft','ArrowRight'].includes(e.key)&&isEdit()){e.preventDefault();const c=S.nle.clips.find(c=>c.id===handle.dataset.clipId);S.nle.selected=c.id;nleEditField({dataset:{nleField:handle.dataset.nleTrim},value:c[handle.dataset.nleTrim]+(e.key==='ArrowRight'?1:-1)/fps()});return;}if(e.key===' '&&(!e.target.closest('button')||e.target.closest('[data-nle-clip],[data-sx-clip],[data-do^="studio:title-"]'))){e.preventDefault();nleAction('play');}if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='k'){e.preventDefault();nleAction('split');}if(!e.metaKey&&!e.ctrlKey){const command={v:'tool-pointer',c:'tool-razor',q:'trim-in',w:'trim-out',ArrowLeft:'prev',ArrowRight:'next'}[e.key];if(command){e.preventDefault();nleAction(command);}}});
