from pathlib import Path
p=Path('docs/ui')
def rep(s,a,b):
 assert a in s,a[:110]
 return s.replace(a,b)
def line(s,start,new):
 ls=s.splitlines();matches=[i for i,v in enumerate(ls) if v.startswith(start)];assert len(matches)==1,(start,matches);ls[matches[0]]=new;return '\n'.join(ls)+'\n'
f=p/'desktop-production-workbench.studio.js';s=f.read_text()
# Selection, locks, animation values and title ownership.
helpers='''const clipEditable=c=>!!c&&!S.running&&!S.nle.tracks.find(t=>t.id===c.track)?.lock;
const titleEditable=()=>!S.running&&!S.nle.tracks.find(t=>t.id===(S.nle.titles[S.studio.titleIndex||0]?.track||'V2'))?.lock;
const clipActions=['key-add','key-delete','grade-reset','load-lut','lut-confirm','swap','swap-confirm','color-match','word-cut'];
const montageActions=['paste','duplicate','delete','ripple','close-gaps','link','swap','swap-confirm','insert','overwrite'];
function parameterValue(c,k,time=S.nle.cursor){const keys=c.keys.filter(x=>x.key===k).sort((a,b)=>a.time-b.time),t=time-c.start;if(!keys.length)return c[k];const a=keys.filter(x=>x.time<=t).at(-1)||keys[0],b=keys.find(x=>x.time>t);if(!b||a.interpolation==='Hold')return a.value;let u=Math.max(0,Math.min(1,(t-a.time)/(b.time-a.time)));if(a.interpolation==='Ease In')u*=u;if(a.interpolation==='Ease Out')u=1-(1-u)**2;if(a.interpolation==='Ease In/Out')u=u*u*(3-2*u);return a.value+(b.value-a.value)*u;}
function parameterSet(c,k,value){if(!c.keys.some(x=>x.key===k)){c[k]=value;return;}const time=Math.max(0,Math.min(nleLength(c),S.nle.cursor-c.start)),x=c.keys.find(x=>x.key===k&&Math.abs(x.time-time)<1/fps());if(x)x.value=value;else c.keys.push({key:k,time,value,interpolation:'Linear'});}
function selectTitle(i){const n=S.nle;if(!n.titles[i])return;stop();n.selected=null;n.marked=[];n.selectedTitle=i;S.studio.titleIndex=i;S.studio.selectedKey=null;S.mediaPreview=false;const t=n.titles[i];if(n.cursor<t.start||n.cursor>=t.end)n.cursor=t.start;if(S.view==='post')S.studio.post='titles';else n.tab='titles';render();persist();}
'''
s=rep(s,'const originalEnsureNLE=ensureNLE;',helpers+'const originalEnsureNLE=ensureNLE;')
s=rep(s,'n.marked??=[];','n.marked??=n.selected?[n.selected]:[];n.selectedTitle??=null;n.titles.forEach(t=>t.track??=\'V2\');')
# Reuse one interpolation implementation.
a=s.index("const key=(k,defaultValue)=>");b=s.index(";return `<div class=\"studio-picture",a)
s=s[:a]+"const key=(k,v)=>parameterValue(c,k,time)??v"+s[b:]
s=rep(s,"S.nle.titles.filter(x=>time>=x.start&&time<x.end)","S.nle.titles.filter(x=>time>=x.start&&time<x.end&&!S.nle.tracks.find(t=>t.id===(x.track||'V2'))?.hidden)")
s=line(s,'nleSelect=function',"""nleSelect=function(id,time=null,multi=false){stop();const n=S.nle;if(!n.clips.some(c=>c.id===id))return;n.selectedTitle=null;n.marked=multi?(n.marked.includes(id)?n.marked.filter(x=>x!==id):[...n.marked,id]):[id];n.selected=n.marked.includes(id)?id:n.marked.at(-1)||null;S.studio.selectedKey=null;const c=nleClip();if(c?.shot!==undefined)S.selected=[c.shot];S.mediaPreview=false;if(c){if(time!==null&&c.id===id)n.cursor=time;else if(n.cursor<c.start||n.cursor>=c.start+nleLength(c))n.cursor=c.start;if(c.type==='audio'){n.tab='audio';if(S.view==='post')S.studio.post='audio';}else if(n.tab==='audio')n.tab='video';}render();persist();};""")
s=rep(s,"draggable=\"${!track?.lock}\"", "draggable=\"${S.view==='edit'&&!track?.lock}\"")
s=rep(s,"${track?.lock?'disabled':''}", "${track?.lock||S.view!=='edit'?'disabled':''}")
s=rep(s,"${NB('tool-razor'", "${S.view==='edit'?NB('tool-razor'")
s=rep(s,"n.tool==='razor')}${NB('split'", "n.tool==='razor'):''}${S.view==='edit'?NB('split'")
s=rep(s,"!nleCanCut())}${SXI('snapping'", "!nleCanCut()):''}${SXI('snapping'")
s=rep(s,"${t.id==='V2'?n.titles.map((x,i)=>", "${n.titles.map((x,i)=>x.track===t.id?")
s=rep(s,"class=\"nle-title-clip\"", "class=\"nle-title-clip\" aria-pressed=\"${n.selectedTitle===i}\"")
s=rep(s,"${E(x.text)}</button>`).join(''):''}", "${E(x.text)}</button>`:'').join('')}")
# Contextual inspector and homogeneous field scope.
s=rep(s,"const c=nleClip(),a=selectedAsset();if(S.mediaPreview", "const c=nleClip(),a=selectedAsset();if(S.nle.selectedTitle!==null||!c&&(S.nle.tab==='titles'||S.studio.post==='titles'))return `<div class=\"inspector-header\"><b>${E(S.nle.titles[S.nle.selectedTitle]?.text||'Titel')}</b><small>Titel · ${S.nle.titles[S.nle.selectedTitle]?.track||'V2'}</small></div>`+studioTitles();if(S.mediaPreview")
s=rep(s,"sxInput(name,'clip-'+k,c[k]", "sxInput(name+(c.keys.some(x=>x.key===k)?' ◆':''),'clip-'+k,parameterValue(c,k)")
s=rep(s,"<b>${E(clipName(c))}</b><small>${S.nle.marked.length>1?S.nle.marked.length+' Clips ausgewählt'", "<b>${S.nle.marked.length>1?S.nle.marked.length+' Clips':E(clipName(c))}</b><small>${S.nle.marked.length>1?'Bildparameter: Videoclips · Tonparameter: alle Clips'")
s=rep(s,"${body}${keyframeControls(c)}`", "${body}${['video','audio'].includes(tab)&&S.nle.marked.length<2?keyframeControls(c):''}`")
s=rep(s,"+SX('word-cut','Füllwörter prüfen…',{cls:'control'})", "+(S.view==='edit'?SX('word-cut','Füllwörter prüfen…',{cls:'control'}):SX('to-edit','Im Schnitt bearbeiten',{cls:'control'}))")
s=rep(s,"SX('audio-sync','Audio synchronisieren…',{cls:'control'})", "SX('audio-sync','Audio synchronisieren…',{cls:'control',disabled:!syncPair()})")
# Mutations honor locks and mode, including direct handler calls.
s=rep(s,"const refresh=()=>studioCommit(S.notice);", "if(command==='delete'&&n.selectedTitle!==null){studioAction('title-delete');return;}if(S.view==='post'&&montageActions.includes(command))return;if(clipActions.includes(command)&&!clipEditable(c))return;if(['title-add','title-delete'].includes(command)&&!titleEditable())return;const refresh=()=>studioCommit(S.notice);")
s=rep(s," if(command.startsWith('settings-'))", " if(command==='to-edit'){switchWorkspace('edit');return;}\n if(command.startsWith('settings-'))")
s=rep(s,"t.titleIndex=+command.slice(6);if(S.view==='post')t.post='titles';else n.tab='titles';inspector();return;", "selectTitle(+command.slice(6));return;")
s=rep(s,"n.selected=n.clips[0]?.id;n.marked=[];", "n.selected=null;n.marked=[];")
s=rep(s,"S.nle.clips.some(c=>c.track===tr.id)", "S.nle.clips.some(c=>c.track===tr.id)||S.nle.titles.some(x=>x.track===tr.id)")
s=rep(s,"if(n.clips.some(c=>c.track===t.track))return;", "if(n.clips.some(c=>c.track===t.track)||n.titles.some(x=>x.track===t.track))return;")
s=rep(s,"n.titles.push({text:'Neuer Titel'", "if(!n.tracks.some(t=>t.id==='V2'))n.tracks.unshift({id:'V2',type:'video',hidden:false,lock:false,sync:true});n.titles.push({track:'V2',text:'Neuer Titel'")
s=rep(s,"t.titleIndex=n.titles.length-1;if(S.view==='post')t.post='titles';else n.tab='titles';S.modal=null;refresh();return;", "S.modal=null;selectTitle(n.titles.length-1);return;")
s=rep(s,"t.titleIndex=0;refresh();return;", "t.titleIndex=0;n.selectedTitle=null;refresh();return;")
s=rep(s,"value:c[key]??0", "value:parameterValue(c,key)??0")
s=rep(s,"else if(key.startsWith('title-')){const title", "else if(key.startsWith('title-')){if(!titleEditable())return;const title")
s=rep(s,"const t=S.studio,c=nleClip(),n=S.nle;if(key.startsWith", "const t=S.studio,c=nleClip(),n=S.nle;if(/^(clip-|fx-|curve-|keyValue|keyTime|keyInterpolation|bypass$|lut$)/.test(key)&&!clipEditable(c))return;if(key.startsWith")
s=rep(s,"const k=key.slice(5);for(const clip of selectedClips().length?selectedClips():[c])", "const k=key.slice(5);if(['in','out','track'].includes(k)&&n.marked.length>1)return;for(const clip of selectedClips().filter(x=>['gain','fadeIn','fadeOut','speed','in','out','track'].includes(k)||x.type!=='audio'))")
s=rep(s,"else clip[k]=value;", "else parameterSet(clip,k,value);")
s=rep(s,"c.fx[key.slice(3)]=value;", "selectedClips().filter(x=>x.type!=='audio').forEach(x=>x.fx[key.slice(3)]=value);")
s=rep(s,"c.fx[k]??=[0,25,50,75,100];c.fx[k][+key.slice(6)]=Math.max(0,Math.min(100,Number(value)));", "for(const x of selectedClips().filter(x=>x.type!=='audio')){x.fx[k]??=[0,25,50,75,100];x.fx[k][+key.slice(6)]=Math.max(0,Math.min(100,Number(value)));}")
s=rep(s,"if(c)c.bypass=value;", "selectedClips().filter(x=>x.type!=='audio').forEach(x=>x.bypass=value);")
s=rep(s,"if(c)c.fx.lut=value;", "selectedClips().filter(x=>x.type!=='audio').forEach(x=>x.fx.lut=value);")
s=rep(s,"if(['exposure','saturation'].includes(k))c[k]=v;else c.fx[k]=v;", "for(const x of selectedClips().filter(x=>x.type!=='audio')){if(['exposure','saturation'].includes(k))x[k]=v;else x.fx[k]=v;}")
# Postproduction keeps transport, navigation, and grading; montage edits stay in Schnitt.
s=rep(s,"nleAction=function(command){S.have.edit=true;", "nleAction=function(command){S.have.edit=true;if(S.view==='post'){if(S.studio.post==='review'&&['play','start','prev','next','end'].includes(command)){finishAction(command);return;}if(['split','trim-in','trim-out','tool-razor','insert'].includes(command))return;}")
s=rep(s,"S.studio.post==='review'?B('finish:mode-film'", "S.studio.post==='review'?B('finish:mode-film'")
s=rep(s,":SX('post-review','Endkontrolle',{cls:'control'})", ":''")
s=rep(s,"if(!['edit','post'].includes(S.view))return;if(cmd&&", "if(!['edit','post'].includes(S.view)||e.target.closest('#nd-browser')||S.mediaPreview)return;if(cmd&&")
s=rep(s,"S.nle.marked=S.nle.clips.map(c=>c.id);render();", "S.nle.marked=S.nle.clips.map(c=>c.id);S.nle.selected=S.nle.marked[0]||null;S.nle.selectedTitle=null;render();")
s=rep(s,"const c=e.target.closest('[data-sx-clip]'),a=e.target.closest('[data-media-drag],[data-library-drag]');if(c)", "const c=e.target.closest('[data-sx-clip]'),a=e.target.closest('[data-media-drag],[data-library-drag]');if(c&&(S.view!=='edit'||!clipEditable(S.nle.clips.find(x=>x.id===c.dataset.sxClip)))){e.preventDefault();return;}if(c)")
s=rep(s,"if(edge){const c=", "if(edge&&S.view==='edit'){const c=")
s=rep(s,"const el=e.target.closest('[data-sx-track]');if(!el)return;", "const el=e.target.closest('[data-sx-track]');if(!el||S.view!=='edit')return;")
# Disallow colliding clip moves before mutation; source insert splits at cursor.
s=rep(s,"if(mode==='insert')n.clips.filter", "if(mode==='insert'){for(const c of [...n.clips]){if(c.start<start&&c.start+nleLength(c)>start&&!n.tracks.find(t=>t.id===c.track)?.lock&&(c.track===track||n.tracks.find(t=>t.id===c.track)?.sync)){const cut=c.in+(start-c.start)*c.speed;n.clips.push({...clone(c),id:'clip-'+n.nextId++,in:cut,start});c.out=cut;}}}if(mode==='insert')n.clips.filter")
s=rep(s,"for(const item of linked){if(studioDrag.duplicate)", "if(linked.some(item=>{const dest=item===c?tr.id:item.track,begin=Math.max(0,item.start+delta);return S.nle.clips.some(x=>(studioDrag.duplicate||!linked.includes(x))&&x.track===dest&&x.start<begin+nleLength(item)&&x.start+nleLength(x)>begin);})){studioDrag=studioSource=null;S.notice='Ziel belegt · freie Stelle wählen oder Überschreiben verwenden';gate();bottom();return;}for(const item of linked){if(studioDrag.duplicate)")
s=rep(s,"id:'clip-'+S.nle.nextId++,start:Math.max(0,item.start+delta)", "id:'clip-'+S.nle.nextId++,track:item===c?tr.id:item.track,start:Math.max(0,item.start+delta)")
# Empty timeline selection and marquee primary selection agree.
s=rep(s,"else if(S.nle.marked.length){S.nle.selected=S.nle.marked[0];inspector();}", "else {S.nle.selected=S.nle.marked[0]||null;S.nle.selectedTitle=null;render();}")
s=rep(s,"add:e.shiftKey};", "add:e.shiftKey};if(!studioMarquee.media&&!e.shiftKey){S.nle.marked=[];S.nle.selected=null;S.nle.selectedTitle=null;}")
# Type-safe inspectors and locked controls are updated even on inspector-only tab changes.
protect='''function protectInspector(){const c=nleClip(),els=sel=>[...$('#nd-inspector').querySelectorAll(sel)];if(c&&!clipEditable(c)){els('input,select,textarea').forEach(x=>x.disabled=true);for(const cmd of clipActions)els('[data-do="studio:'+cmd+'"]').forEach(x=>x.disabled=true);const head=$('#nd-inspector .inspector-header small');if(head)head.textContent+=' · Spur gesperrt';}if(S.nle.selectedTitle!==null&&!titleEditable())els('input,select,textarea,[data-do="studio:title-delete"],[data-do="studio:title-add"]').forEach(x=>x.disabled=true);if(S.nle.marked.length>1){els('[data-sx="clip-in"],[data-sx="clip-out"],[data-sx="clip-track"]').forEach(x=>x.disabled=true);els('[data-sx^="clip-"]').forEach(el=>{const k=el.dataset.sx.slice(5),v=selectedClips().filter(x=>['gain','fadeIn','fadeOut','speed'].includes(k)||x.type!=='audio').map(x=>parameterValue(x,k));if(new Set(v).size>1&&el.type==='number'){el.value='';el.placeholder='Gemischt';}});}}
'''
s=rep(s,'inspector=function(){if(S.view',protect+'inspector=function(){if(S.view')
s=rep(s,"?finishInspector():studioClipInspector();return;}oldInspector();if(workspace()==='production')productionInspectorExtras();};", "?finishInspector():studioClipInspector();}else{oldInspector();if(workspace()==='production')productionInspectorExtras();}protectInspector();};")
s=rep(s,"if(el.type==='number'&&(!Number.isFinite(value)||!el.validity.valid))", "if(el.type==='number'&&(!el.value.trim()||!Number.isFinite(value)||!el.validity.valid))")
# Tests belong outside the product shell.
s=rep(s,"+sxCheck('Backend bereit · Demo','ready',t.ready)", "")
s=rep(s,"+SX('pack-missing','Fehlende Version simulieren',{cls:'control'})", "")
s=rep(s,'min="90" max="130"','min="100" max="130"')
s=rep(s,'S.studio.uiScale/100','Math.max(1,S.studio.uiScale/100)')
f.write_text(s)
f=p/'desktop-production-workbench.edit.js';s=f.read_text();s=rep(s,'n.selected=after.id;', 'n.selected=after.id;n.marked=[after.id];n.selectedTitle=null;');s=rep(s,"if(S.view!=='edit'||!S.have.edit", "if(!['edit','post'].includes(S.view)||!S.have.edit");s=rep(s,"e.target.closest('[data-nle-clip]')", "e.target.closest('[data-nle-clip],[data-sx-clip],[data-do^=\"studio:title-\"]')");f.write_text(s)
f=p/'desktop-production-workbench.finish.js';s=f.read_text();s=rep(s,'const finishHasCut=',"const visibleVideo=()=>finishClips().filter(c=>!S.nle.tracks.find(t=>t.id===c.track)?.hidden);\nconst finishHasCut=");s=rep(s,"audio:[S.nle?.gain,S.nle?.muted,S.track],hidden:S.nle?.hidden,", "");s=rep(s,"if(S.nle.hidden)", "if(!visibleVideo().length)");s=rep(s,"title:'Videospur ausgeblendet',detail:'V1 ist ausgeschaltet. Die Ausgabe braucht sichtbares Video.'", "title:'Keine sichtbare Videospur',detail:'Alle belegten Videospuren sind ausgeblendet. Mindestens eine Bildspur einblenden.'");f.write_text(s)
f=p/'desktop-production-workbench.studio.js';s=f.read_text().replace("!S.nle.hidden&&(!S.finish.requireReview", "visibleVideo().length>0&&(!S.finish.requireReview");f.write_text(s)
