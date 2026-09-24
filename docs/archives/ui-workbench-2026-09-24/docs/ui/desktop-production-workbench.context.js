const contextBase={action,studioAction,menuItems,dialog,render,inspector};
let objectMenu=null,objectTarget=null,dismissObjectClick=false;
const objectItem=(command,label,disabled=false,shortcut='',checked)=>({cmd:'object:'+command,label,disabled,shortcut,checked});
const objectSelector=(attribute,value)=>'['+attribute+'="'+CSS.escape(String(value))+'"]';
function objectAt(node,event){
 if(!node?.closest||node.closest('input,textarea,select,[contenteditable=true],#nd-overlay,#nd-menubar'))return null;
 const match=(selector,kind,key)=>{const el=node.closest(selector);return el?{kind,id:key(el),selector:el.dataset.do?objectSelector('data-do',el.dataset.do):selector,view:S.view}:null;};
 let d=match('[data-do^="asset:"]','asset',el=>el.dataset.do.slice(6))||match('[data-do^="pool:folder-"]','folder',el=>el.dataset.do.slice(12))||match('.nle-clip','clip',el=>el.querySelector('[data-sx-clip]')?.dataset.sxClip)||match('.nle-title-clip','title',el=>Number(el.dataset.do.split('-').at(-1)))||match('.studio-track-head','track',el=>el.querySelector('[data-do^="studio:track-"]').dataset.do.slice(13));
 if(d){if(d.kind==='clip')d.selector=objectSelector('data-sx-clip',d.id);if(d.kind==='track')d.selector=objectSelector('data-do','studio:track-'+d.id);return d;}
 const hit=node.closest('[data-do^="studio:moment-"]');if(hit){const [id,index]=hit.dataset.do.slice(14).split('~');return {kind:'asset',id,hit:+index,selector:objectSelector('data-do',hit.dataset.do),view:S.view};}
 const reviewClip=node.closest('[data-do^="finish:clip-"],[data-do^="studio:review-clip-"]');if(reviewClip){const cmd=reviewClip.dataset.do,id=cmd.startsWith('finish:')?finishClips()[+cmd.slice(12)]?.id:cmd.slice(19);return {kind:'review-clip',id,selector:objectSelector('data-do',cmd),view:S.view};}
 const take=node.closest('[data-take]');if(take)return {kind:'take',id:+take.dataset.take,shotID:S.shots[+take.dataset.takeShot]?.id,selector:objectSelector('data-take',take.dataset.take)+objectSelector('data-take-shot',take.dataset.takeShot),view:S.view};
 const shotEl=node.closest('[data-shot]');if(shotEl)return {kind:'shot',id:S.shots[+shotEl.dataset.shot]?.id,selector:objectSelector('data-shot',shotEl.dataset.shot),view:S.view};
 d=match('[data-do^="moment:"]','moment',el=>+el.dataset.do.slice(7))||match('[data-do^="studio:entity-"]:not([data-do^="studio:entity-filter-"])','entity',el=>+el.dataset.do.slice(14))||match('[data-do^="clay:object-"]','clay-object',el=>el.dataset.do.slice(12))||match('[data-do^="clay:shot-"],[data-do^="clay:output-"]','clay-shot',el=>S.shots[+el.dataset.do.split('-').at(-1)]?.id)||match('[data-section]','section',el=>+el.dataset.section)||match('[data-do^="finish:export-"]','export',el=>+el.dataset.do.slice(14))||match('[data-do^="finish:finding-"]','finding',el=>el.dataset.do.slice(15))||match('[data-do^="studio:key-"]','key',el=>+el.dataset.do.slice(11));
 if(d){if(d.kind==='moment')d.shotID=shot()?.id;if(d.kind==='section')d.selector=objectSelector('data-section',d.id);if(['key','entity'].includes(d.kind)&&!Number.isInteger(d.id))return null;return d;}
 const clay=node.closest('.clay-stage canvas');if(clay){const rect=clay.getBoundingClientRect(),hit=event&&(clay.clayHits||[]).map(p=>({...p,d:Math.hypot(p.x-event.clientX+rect.x,p.y-event.clientY+rect.y)})).filter(p=>p.d<24).sort((a,b)=>a.d-b.d)[0];return {kind:hit&&clayScene()?.objects.some(o=>o.id===hit.id)?'clay-object':'clay-scene',id:hit?.id||clayScene()?.id,selector:'.clay-stage canvas',view:S.view};}
 if(node.closest('.pool-results,.pool-folders')&&workspace()==='media')return {kind:'library',id:'library',selector:'.pool-results',view:S.view};
 if(node.closest('.nle-lane,.nle-content'))return {kind:'timeline',id:'sequence',selector:'.nle-toolbar [data-do="studio:clip-menu"]',view:S.view};
 return null;
}
function defaultObject(){
 if(S.view==='media')return selectedAsset()?{kind:'asset',id:S.mediaSelection,view:S.view}:{kind:'library',view:S.view};
 if(['edit','post'].includes(S.view)){if(S.mediaPreview&&selectedAsset())return {kind:'asset',id:S.mediaSelection,view:S.view};return S.nle.selectedTitle!==null?{kind:'title',id:S.nle.selectedTitle,view:S.view}:nleClip()?{kind:'clip',id:S.nle.selected,view:S.view}:{kind:'timeline',view:S.view};}
 if(S.view==='audio'&&S.audioReady)return {kind:'section',id:S.section,view:S.view};
 if(S.view==='blocking'&&clayScene())return {kind:'clay-scene',id:clayScene().id,view:S.view};
 if(S.view==='takes'&&S.takeViewer)return {kind:'take',id:S.studio.takeFocus,shotID:shot()?.id,view:S.view};
 if(S.view==='refs'&&S.refMode==='identities'&&S.identities)return {kind:'entity',id:S.studio.entity,view:S.view};
 if(['board','plan','refs','review','takes'].includes(S.view)&&shot())return {kind:'shot',id:shot().id,view:S.view};
 if(S.view==='finish'&&S.finishSection==='history'&&S.finish.selectedExport)return {kind:'export',id:S.finish.selectedExport,view:S.view};
 return null;
}
function selectObject(d){
 if(d.kind==='asset'){if(workspace()==='media'&&S.mediaMarked.includes(d.id)){S.mediaSelection=d.id;inspector();}else if(S.mediaSelection!==d.id||workspace()!=='media'&&!S.mediaPreview)selectMedia(d.id);}
 if(d.kind==='asset'&&d.hit!==undefined&&S.mediaMarked.length<=1)studioAction('moment-'+d.id+'~'+d.hit);
 if(d.kind==='review-clip'){const c=S.nle.clips.find(c=>c.id===d.id);if(c){S.finish.mode='film';S.finish.cursor=c.start;render();}}
 if(d.kind==='folder'&&S.mediaFolder!==d.id)poolAction('folder-'+d.id);
 if(d.kind==='clip'){if(!S.nle.marked.includes(d.id))nleSelect(d.id);else {S.nle.selected=d.id;S.mediaPreview=false;render();}}
 if(d.kind==='title'&&(S.nle.selectedTitle!==d.id||S.mediaPreview))selectTitle(d.id);
 if(d.kind==='track')S.studio.track=d.id;
 if(d.kind==='shot'&&!S.selected.some(i=>S.shots[i]?.id===d.id))choose(S.shots.findIndex(s=>s.id===d.id));
 if(d.kind==='moment')action('moment:'+d.id);
 if(d.kind==='entity')studioAction('entity-'+d.id);
 if(d.kind==='take'){const i=S.shots.findIndex(s=>s.id===d.shotID);if(i<0)return;S.selected=[i];S.studio.takeFocus=d.id;S.takeNote=S.studio.takeReviews[i+'-'+d.id]?.note||'';inspector();}
 if(d.kind==='clay-object'){S.clay.selection=d.id;inspector();clayDrawSoon();}
 if(d.kind==='clay-shot')action('clay:shot-'+S.shots.findIndex(s=>s.id===d.id));
 if(d.kind==='section'){audioStop();S.section=d.id;S.audioPosition=sections[d.id][1];canvas();inspector();paintIcons();}
 if(d.kind==='export')finishAction('export-'+d.id);
 if(d.kind==='finding')finishAction('finding-'+d.id);
 if(d.kind==='key')studioAction('key-'+d.id);
}
function objectCommands(d){
 if(!d||d.view!==S.view)return [];
 const I=objectItem,locked=S.running||S.studio.packAvailable===false||!workflowPacks[S.pack],editable=isEdit(),single=S.selected.length===1,revise=S.done[S.view]?[null,I('revise',labels[S.view]+' revidieren…',locked)]:[];
 const inspect=I('inspect','Im Inspector zeigen'),reveal=id=>I('reveal-'+id,'In Medien zeigen',!assets().some(a=>a.id===id));
 if(d.kind==='library'||d.kind==='folder'){const folder=d.kind==='folder'&&d.id!=='all',exists=folder&&mediaFolders().some(f=>f.id===d.id);return [I('media-import','Medien importieren…',locked),I('gen:open','Medien generieren…',locked),null,I('pool:new',folder?'Unterordner anlegen…':'Ordner anlegen…',locked),...(folder?[I('pool:rename','Umbenennen…',locked||!exists),null,I('studio:folder-delete','Ordner entfernen…',locked||!exists)]:[])];}
 if(d.kind==='asset'){
  const a=assets().find(a=>a.id===d.id);if(!a)return [];
  const library=workspace()==='media',ids=library&&S.mediaMarked.includes(d.id)?S.mediaMarked:[d.id],one=ids.length===1;
  const protectedAsset=id=>/^(document-|sketch-|identity-|anchor-|take-)/.test(id)||id==='track'||id==='lyrics'||S.shots.some(s=>s.anchorVariant===id||s.sourceFile===assets().find(a=>a.id===id)?.name)||[S.trackMediaId,S.lyricsMediaId].includes(id);
  const insertable=S.view==='edit'&&!a.offline&&a.type!=='text'&&S.nle.tracks.some(t=>t.type===(a.type==='audio'?'audio':'video')&&!t.lock);
  return [inspect,...(a.phase?[I('pool:document','In '+labels[a.phase]+' öffnen',!one)]:a.shot!==undefined?[I('media-locate','In Produktion zeigen',!one)]:[]),...(!library?[I('pool:reveal','In Medien zeigen'),...(S.view==='edit'?[null,I('studio:insert','Am Abspielkopf einsetzen',locked||!insertable),I('studio:overwrite','Am Abspielkopf überschreiben',locked||!insertable)]:[])]:[null,I('studio:asset-rename','Umbenennen…',locked||!one),I('pool:move','In Ordner verschieben…',locked)]),null,I('studio:asset-path','Dateiort anzeigen',locked||!one),...(a.offline?[I('studio:asset-relink','Neu verknüpfen…',locked||!one)]:[]),...(library?[null,I('studio:asset-delete',ids.length>1?'Medien aus Projekt entfernen…':'Medium aus Projekt entfernen…',locked||ids.some(protectedAsset))]:[])];
 }
 if(d.kind==='clip'||d.kind==='timeline'){
  const n=S.nle,ids=n.marked.length?n.marked:n.selected?[n.selected]:[],clips=n.clips.filter(c=>ids.includes(c.id)),all=clips.length>0&&clips.every(clipEditable),one=clips.length===1,c=clips[0],edit=S.view==='edit'&&!locked,selected=d.kind==='clip'&&clips.length>0;
  const paste=edit&&n.selectedTitle===null&&S.studio.clipboard?.length&&S.studio.clipboard.every(c=>n.tracks.some(t=>t.id===c.track&&!t.lock));
  if(!selected)return [I('studio:paste','Einsetzen',!paste,'⌘V'),null,I('studio:add-track','Spur hinzufügen…',locked),I('studio:range','Bereich auswählen…',locked||!n.clips.length),I('studio:close-gaps','Lücken in der Sequenz schließen',!edit||!n.clips.some(c=>!n.tracks.find(t=>t.id===c.track)?.lock))];
  if(S.view==='post')return [I('studio:copy','Kopieren',!all,'⌘C'),inspect,...(one&&c?.asset?[reveal(c.asset)]:[]),null,I('studio:save-media','Als Medium sichern',locked||!one||c?.type==='audio')];
  const cut=edit&&all&&one&&nleCanCut(),linked=clips.some(c=>c.link);
  return [I('studio:copy','Kopieren',!all,'⌘C'),I('cut-clips','Ausschneiden',!edit||!all,'⌘X'),I('studio:paste','Einsetzen',!paste,'⌘V'),I('studio:duplicate','Duplizieren',!edit||!all),null,I('nle:split','Am Abspielkopf teilen',!cut,'⌘K'),I('nle:trim-in','Anfang bis Abspielkopf trimmen',!cut,'Q'),I('nle:trim-out','Ende bis Abspielkopf trimmen',!cut,'W'),null,I(linked?'unlink-clips':'studio:link',linked?'Verbindung lösen':'Clips verbinden',!edit||!all||(!linked&&!clips.some((_,i)=>i>0))||linked&&n.clips.some(c=>clips.some(x=>x.link&&x.link===c.link)&&!clipEditable(c))),I('studio:swap','Quelle austauschen…',!edit||!all||!one),I('studio:audio-sync','Audio synchronisieren…',!edit||!all||!syncPair()),I('studio:save-media','Als Medium sichern',locked||!one||c?.type==='audio'),...(one&&c?.asset?[reveal(c.asset)]:[]),inspect,null,I('studio:delete','Löschen',!edit||!all,'⌫'),I('studio:ripple','Löschen und Lücke schließen',!edit||!all,'⇧⌫')];
 }
 if(d.kind==='review-clip'){const c=S.nle.clips.find(c=>c.id===d.id);if(!c)return [];return [I('clip-in-edit','Im Schnitt zeigen'),...(c.asset?[reveal(c.asset)]:[])];}
 if(d.kind==='title'){const title=S.nle.titles[d.id];if(!title)return [];return [I('inspect-title',title.caption?'Untertitel bearbeiten':'Titel bearbeiten',locked||!titleEditable()),null,I('studio:title-delete',title.caption?'Untertitel löschen':'Titel löschen',locked||!titleEditable(),'⌫')];}
 if(d.kind==='track'){const t=S.nle.tracks.find(t=>t.id===d.id);if(!t)return [];return [I('studio:track-'+t.id,'Spureinstellungen…',locked),null,I('studio:track-lock-'+t.id,'Spur sperren',locked,'',t.lock),I('studio:track-hide-'+t.id,t.type==='audio'?'Stummschalten':'Ausblenden',locked,'',t.hidden),null,I('studio:track-remove','Leere Spur entfernen',locked||t.lock||S.nle.clips.some(c=>c.track===t.id)||S.nle.titles.some(x=>x.track===t.id))];}
 if(d.kind==='shot'){
  if(S.view==='board')return boardContextItems().map(x=>x?{...x,cmd:'object:'+x.cmd,disabled:x.disabled||x.cmd==='revise'&&locked}:x);
  const s=S.shots.find(s=>s.id===d.id);if(!s)return [];const i=S.shots.indexOf(s),navigation=[I('open:board','Im Storyboard zeigen',!single),I('open:plan','In Shotplanung zeigen',!single)];
  if(S.view==='plan')return [inspect,I('studio:source-binding','Quellen prüfen',locked||!single),null,I('open:blocking','Blocking öffnen',!single),navigation[0],...revise];
  if(S.view==='refs')return [inspect,I('wf:refs-compare','Sketch / Anker vergleichen',!single||!hasAnchor(s.id)),reveal('anchor-'+i),null,I('wf:anchors-accept','Auswahl bestätigen',!editable||!S.selected.length||S.selected.some(j=>S.shots[j].source!=='KI-Video'||!hasAnchor(S.shots[j].id)||S.clay.staleAnchorIds.includes(S.shots[j].id))),null,...navigation,...revise];
  if(S.view==='takes')return [I('inspect-take','Takes prüfen',!single||!S.takes[i]?.length),...navigation,...revise];
  return [inspect,...navigation,I('open:refs','References zeigen',!single),...revise];
 }
 if(d.kind==='moment')return [I('inspect-moment','Handlung und Zeitpunkt bearbeiten',!editable),I('sketch-source','Sketch aus Medien wählen…',!editable),null,I('add-moment','Handlungsmoment hinzufügen',!editable||moments().length>=6),reveal('sketch-'+at()+'-'+d.id),...revise];
 if(d.kind==='take'){const i=S.shots.findIndex(s=>s.id===d.shotID),valid=(S.takes[i]||[]).includes(d.id)&&S.mode!=='history';return [I('inspect-take','Take prüfen',!valid),reveal(valid?activeTakeAssetID(i,d.id):''),null,I('retake-cost','Weiteren Take erzeugen…',!valid||!editable||S.shots[i]?.source!=='KI-Video'),...revise];}
 if(d.kind==='entity')return [inspect,I('studio:entity-edit','Änderung vorschlagen…',!editable),...revise];
 if(d.kind==='clay-object')return [inspect,I('clay:endpoint-start','Anfangsposition zeigen'),I('clay:endpoint-end','Endposition zeigen'),...revise];
 if(d.kind==='clay-scene')return [I('clay:plan','Draufsicht',false,'',S.clay.plan),I('clay:inspect','Shot-Kamera zeigen'),null,I('clay:duplicate-location','Location duplizieren',!editable),...revise];
 if(d.kind==='clay-shot')return [I('clay:inspect','Shot-Kamera zeigen'),...(S.clay.view==='outputs'?[]:[I('clay:view-outputs','Clay-Vorlagen zeigen')]),null,I('clay:accept','Vorlage bestätigen',!editable||!clayOutputValid(d.id)||S.clay.outputs[d.id]?.accepted),I('open:plan','In Shotplanung zeigen'),...revise];
 if(d.kind==='section')return [I('wf:audio-play',S.audioRunning?'Abhören anhalten':'Abschnitt abhören'),I('wf:audio-loop','Abschnitt wiederholen',false,'',S.audioLoop),null,I('studio:analysis-proof','Messdetails zeigen',locked)];
 if(d.kind==='export'){const x=S.finish.exports.find(x=>x.id===d.id);if(!x)return [];return [inspect,I('finish-section:delivery','Weitere Ausgabe vorbereiten',locked),...(x.status==='running'?[null,I('finish:cancel','Export stoppen',S.finish.job?.id!==x.id)]:[])];}
 if(d.kind==='finding'){const f=S.finish.findings.find(x=>x.id===d.id);if(!f)return [];return [inspect,I('finish:repair','Im Schnitt korrigieren…',locked),I('finish:accept-finding','Abweichung begründen…',locked||f.severity==='blocking'||f.accepted||!finishCurrentScan())];}
 if(d.kind==='key')return [inspect,null,I('studio:key-delete','Keyframe löschen',!clipEditable(nleClip())||!nleClip()?.keys[d.id])];
 return [];
}
function objectFocus(d){const fallback=workspace()==='media'?objectSelector('data-do','asset:'+S.mediaSelection):['edit','post'].includes(S.view)?objectSelector('data-sx-clip',S.nle.selected):S.view==='takes'&&S.takeViewer?objectSelector('data-do','wf:take-'+S.studio.takeFocus):objectSelector('data-shot',at());const el=(d?.view===S.view&&d.selector?$(d.selector):null)||$(fallback);(el?.matches('button')?el:el?.querySelector('button'))?.focus({preventScroll:true});}
function closeObjectMenu(focus=false){const d=objectMenu?.target;objectMenu=null;if(S.modal==='object-menu')S.modal=null;$('.object-menu')?.remove();if(focus)objectFocus(d);drawMenuBar();}
function openObjectMenu(d,x,y){
 if(!d||S.modal&& !['object-menu','native-menu'].includes(S.modal))return;
 closeObjectMenu();if(S.modal==='native-menu')closeNativeMenu(false);selectObject(d);const items=objectCommands(d);if(!items.length)return;
 objectTarget=d;objectMenu={target:d,x,y,scrolls:new Map([root,...$$('*')].filter(el=>el.scrollHeight>el.clientHeight||el.scrollWidth>el.clientWidth).map(el=>[el,[el.scrollLeft,el.scrollTop]]))};S.modal='object-menu';dialog();$('.object-menu button:not(:disabled)')?.focus({preventScroll:true});
}
function constrainMenu(menu,x,y){
 const b=root.getBoundingClientRect(),top=Math.max(b.top,0)+4,bottom=Math.min(b.bottom,innerHeight)-4,left=Math.max(b.left,0)+4,right=Math.min(b.right,innerWidth)-4;
 menu.style.maxHeight=Math.max(80,bottom-top)+'px';menu.style.maxWidth=Math.max(160,right-left)+'px';const r=menu.getBoundingClientRect();menu.style.left=Math.max(left,Math.min(x,right-r.width))-b.left+'px';menu.style.top=Math.max(top,Math.min(y,bottom-r.height))-b.top+'px';
}
dialog=function(){
 if(S.modal==='object-menu'&&objectMenu){const {target,x,y}=objectMenu;$('#nd-overlay').innerHTML='<section class="context-menu object-menu" role="menu" aria-label="Objektaktionen">'+objectCommands(target).map(i=>i?B(i.cmd,'<span class="menu-check" aria-hidden="true">'+(i.checked?'✓':'')+'</span><span class="menu-label">'+E(i.label)+'</span><kbd>'+E(i.shortcut||'')+'</kbd>',{disabled:i.disabled,attrs:'role="'+(i.checked===undefined?'menuitem':'menuitemcheckbox')+'" '+(i.checked===undefined?'':'aria-checked="'+i.checked+'" ')+'data-object-command'}):'<hr role="separator">').join('')+'</section>';constrainMenu($('.object-menu'),x,y);return;}
 contextBase.dialog();if(S.modal==='native-menu'){const el=$('#nd-native-menu'),r=el?.getBoundingClientRect();if(r)constrainMenu(el,r.left,r.top);}
};
function runObjectCommand(command,d){
 const item=objectCommands(d).find(i=>i?.cmd==='object:'+command);if(!item||item.disabled)return;
 if(command==='inspect'||command.startsWith('inspect-')){
  if(command==='inspect-take'){S.takeViewer=true;if(d.kind!=='take')S.studio.takeFocus=S.chosen[at()]||S.takes[at()]?.[0];}
  S.inspector=true;if(d.kind==='clay-object')S.clay.view='space';render();const selector=command==='inspect-moment'?'[data-field="momentLabel"]':command==='inspect-title'?'[data-sx="title-text"]':null;const input=selector&&$(selector);if(input){input.closest('details').open=true;input.focus();input.select?.();}else objectFocus(d);return;
 }
 if(command==='clip-in-edit'){const id=d.id;switchWorkspace('edit');nleSelect(id);objectFocus(d);return;}
 if(command.startsWith('reveal-')){S.mediaSelection=command.slice(7);revealMedia();return;}
 if(command==='cut-clips'){studioAction('copy');studioAction('delete');return;}
 if(command==='unlink-clips'){checkpoint();const groups=new Set(selectedClips().map(c=>c.link).filter(Boolean));S.nle.clips.filter(c=>groups.has(c.link)).forEach(c=>c.link=null);render();persist();return;}
 if(command==='studio:track-remove')S.studio.track=d.id;
 if(command==='pool:new'&&d.kind==='library')S.mediaFolder='all';
 action(command);
}
action=function(command){
 if(command.startsWith('object:')){const d=objectMenu?.target||objectTarget;closeObjectMenu();runObjectCommand(command.slice(7),d);if(!S.modal&&!command.includes('inspect')&&!command.endsWith('wf:rename'))objectFocus(d);return;}
 if(objectMenu)closeObjectMenu();contextBase.action(command);
};
studioAction=function(command){
 if(command==='asset-menu'||command==='clip-menu'){const d=command==='asset-menu'?{kind:'asset',id:S.mediaSelection,selector:objectSelector('data-do','asset:'+S.mediaSelection),view:S.view}:S.nle.selectedTitle!==null?{kind:'title',id:S.nle.selectedTitle,view:S.view}:nleClip()?{kind:'clip',id:S.nle.selected,selector:objectSelector('data-sx-clip',S.nle.selected),view:S.view}:{kind:'timeline',view:S.view};const el=$('[data-do="studio:'+command+'"]')||$('#nd-canvas'),b=el.getBoundingClientRect();openObjectMenu(d,b.right,b.bottom);return;}
 if(['asset-rename','asset-delete','asset-path','asset-relink','asset-rename-save','asset-delete-confirm','asset-relink-confirm'].includes(command)){const base=command.replace(/-save$|-confirm$/,'');const item=objectCommands({kind:'asset',id:S.mediaSelection,view:S.view}).find(i=>i?.cmd==='object:studio:'+base);if(!item||item.disabled)return;}
 contextBase.studioAction(command);
};
menuItems=function(key){
 if(key!=='edit'||menuTextTarget?.isConnected)return contextBase.menuItems(key);
 const t=objectTarget,valid=t?.view===S.view&&(t.kind!=='asset'||t.id===S.mediaSelection)&&(t.kind!=='shot'||S.selected.some(i=>S.shots[i]?.id===t.id))&&(t.kind!=='clip'||S.nle.marked.includes(t.id))&&(t.kind!=='folder'||t.id===S.mediaFolder);const d=valid?t:defaultObject(),items=objectCommands(d);if(!items.length)return contextBase.menuItems(key);objectTarget=d;
 const standard=contextBase.menuItems(key).slice(0,3),select=['asset','library','clip','timeline','shot'].includes(d.kind)?[objectItem('select-all','Alles auswählen',d.kind==='shot'?!S.shots.length:d.kind==='asset'||d.kind==='library'?workspace()!=='media'||!poolItems().length:!S.nle.clips.length,'⌘A'),null]:[];
 return [...standard,...select,...items];
};
const contextExecute=runObjectCommand;
runObjectCommand=function(command,d){if(command==='select-all'){if(!d||d.view!==S.view)return;if(d.kind==='shot')S.selected=S.shots.map((_,i)=>i);else if((d.kind==='asset'||d.kind==='library')&&workspace()==='media'){S.mediaMarked=poolItems().map(a=>a.id);S.mediaSelection=S.mediaMarked[0];}else if(['clip','timeline'].includes(d.kind)){S.nle.marked=S.nle.clips.map(c=>c.id);S.nle.selected=S.nle.marked[0];S.nle.selectedTitle=null;}else return;render();persist();return;}contextExecute(command,d);};
inspector=function(){contextBase.inspector();if(selectedAsset()){const items=objectCommands({kind:'asset',id:S.mediaSelection,view:S.view});for(const b of $$('#nd-inspector [data-do^="studio:asset-"]')){const item=items.find(i=>i?.cmd==='object:'+b.dataset.do);b.disabled=!item||item.disabled;}}};
render=function(){if(objectMenu)closeObjectMenu();contextBase.render();};
root.addEventListener('contextmenu',e=>{if(e.target.closest('input,textarea,select,[contenteditable=true]'))return;const d=objectAt(e.target,e);if(!d)return;e.preventDefault();e.stopImmediatePropagation();openObjectMenu(d,e.clientX,e.clientY);},true);
root.addEventListener('pointerdown',e=>{
 if(objectMenu&&!e.target.closest('.object-menu')){closeObjectMenu();if(e.button===0&&!e.ctrlKey){dismissObjectClick=true;e.preventDefault();e.stopImmediatePropagation();return;}}
 if(e.ctrlKey&&e.button===0&&objectAt(e.target,e)){e.preventDefault();e.stopImmediatePropagation();return;}
 if(!S.modal&&!e.target.closest('#nd-menubar'))objectTarget=objectAt(e.target,e);
},true);
root.addEventListener('click',e=>{
 if(dismissObjectClick){dismissObjectClick=false;e.preventDefault();e.stopImmediatePropagation();return;}
 const b=e.target.closest('[data-object-command]');if(b){e.preventDefault();e.stopImmediatePropagation();if(!b.disabled)action(b.dataset.do);return;}
 if(e.ctrlKey&&!e.metaKey){const d=objectAt(e.target,e);if(d){e.preventDefault();e.stopImmediatePropagation();openObjectMenu(d,e.clientX,e.clientY);}}
},true);
root.addEventListener('focusin',e=>{if(!S.modal&&!e.target.closest('#nd-menubar')){const d=objectAt(e.target);if(d)objectTarget=d;}});
root.addEventListener('keydown',e=>{
 if(objectMenu){e.stopImmediatePropagation();const items=$$('.object-menu button:not(:disabled)'),i=items.indexOf(document.activeElement);if(e.key==='Escape'||e.key==='Tab'){e.preventDefault();closeObjectMenu(true);return;}if(['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();const index=e.key==='Home'?0:e.key==='End'?items.length-1:i<0?(e.key==='ArrowUp'?items.length-1:0):(i+(e.key==='ArrowUp'?-1:1)+items.length)%items.length;items[index]?.focus();items[index]?.scrollIntoView({block:'nearest'});}if(e.key==='Enter'||e.key===' '){e.preventDefault();items[i]?.click();}return;}
 if(!S.modal&&(e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='a'&&!e.target.closest('input,textarea,select,[contenteditable=true]')&&(S.view==='board'||workspace()==='media')){e.preventDefault();e.stopImmediatePropagation();runObjectCommand('select-all',defaultObject());return;}
 if(e.key==='ContextMenu'||e.shiftKey&&e.key==='F10'){const d=objectAt(e.target);if(d){e.preventDefault();e.stopImmediatePropagation();const b=e.target.getBoundingClientRect();openObjectMenu(d,b.left+12,b.top+12);}}
},true);
root.addEventListener('pointermove',e=>{if(objectMenu){const b=e.target.closest('[data-object-command]:not(:disabled)');if(b)b.focus({preventScroll:true});}});
root.addEventListener('scroll',e=>{if(!objectMenu||e.target.closest?.('.object-menu'))return;const before=objectMenu.scrolls.get(e.target);if(before&&(before[0]!==e.target.scrollLeft||before[1]!==e.target.scrollTop))closeObjectMenu();},true);
document.addEventListener('pointerdown',e=>{if(objectMenu&&!root.contains(e.target))closeObjectMenu();},true);
window.addEventListener('resize',()=>closeObjectMenu());
window.addEventListener('blur',()=>closeObjectMenu());
