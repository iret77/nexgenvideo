const navigationBase={chrome,dialog,render,renderTask,task,action,studioAction,restore,undoContent};
const menuNames={app:'NexGenVideo',file:'Ablage',edit:'Bearbeiten',view:'Darstellung',window:'Fenster',help:'Hilfe'};
let activeMenu='',menuReturn=null,menuTextTarget=null,menuContentTarget=null,textClipboard='';
const appPreferenceKeys=['settings','providers','disabledModels','backend','ready','connections','uiScale','notify','telemetry','modelEvidence','removedVersion','cacheCleared','packUpdateAvailable','appNotice'];
const appPreferences=()=>Object.fromEntries(appPreferenceKeys.map(k=>[k,clone(S.studio[k]??studioDefaults()[k]??null)]));
function applyAppPreferences(p){Object.assign(S.studio,p);render();}
function menuItems(key){
 const item=(cmd,label,shortcut='',disabled=false)=>({cmd,label,shortcut,disabled});
 if(key==='app')return [item('studio:settings','Einstellungen…','⌘,',S.running),null,item('studio:update-check','Nach Updates suchen…','',S.running)];
 if(key==='file')return [item('studio:new','Neues Projekt…','⌘N',S.running),item('studio:open-project','Projekt öffnen…','⌘O',S.running),null,item('studio:save-project','Sichern','⌘S',S.running),item('studio:save-copy','Kopie sichern…','',S.running),null,item('studio:project-settings','Projekteinstellungen…','',S.running),null,item('media-import','Medien importieren…','',S.running),item('workspace:finish','Export öffnen')];
 const text=menuTextTarget?.isConnected?menuTextTarget:null,selection=!!text&&text.selectionEnd>text.selectionStart;
 const timeline=['edit','post'].includes(S.view)&&!S.mediaPreview&&!text&&!(menuContentTarget?.isConnected&&menuContentTarget.closest('#nd-browser')),clips=timeline?selectedClips():[],edit=S.view==='edit'&&!S.running;
 const board=S.view==='board'&&!text,cuttable=timeline&&edit&&S.nle.marked.length<=1&&S.nle.selectedTitle===null&&nleCanCut();
 const allUnlocked=clips.length>0&&(S.nle.marked.length||1)===clips.length;
 if(key==='edit')return [item('undo','Rückgängig','⌘Z',!undo.length||S.running),item('redo','Wiederholen','⇧⌘Z',!redo.length||S.running),null,
  item('native:cut','Ausschneiden','⌘X',S.running||!(text?selection&&!text.readOnly:edit&&allUnlocked)),
  item('native:copy','Kopieren','⌘C',!(text?selection:allUnlocked)),
  item('native:paste','Einsetzen','⌘V',S.running||!(text?!text.readOnly&&!!textClipboard:timeline&&edit&&S.studio.clipboard?.length&&S.studio.clipboard.every(c=>S.nle.tracks.some(t=>t.id===c.track&&!t.lock)))),
  item('native:delete','Löschen','⌫',S.running||!(text?selection&&!text.readOnly:board?isEdit()&&!!shot():timeline&&edit&&(allUnlocked||S.nle.selectedTitle!==null&&titleEditable()))),
  item('native:select-all','Alles auswählen','⌘A',!(text||board&&S.shots.length||timeline&&S.nle.clips.length)),null,
  ...(board?boardContextItems().slice(0,-2):[item('nle:split','Am Abspielkopf teilen','⌘K',!cuttable),item('nle:trim-in','Anfang bis Abspielkopf trimmen','Q',!cuttable),item('nle:trim-out','Ende bis Abspielkopf trimmen','W',!cuttable),null,
  item('studio:assembly','Geprüfte Takes montieren…','',!edit||!S.done.takes||!S.shots.length||S.shots.some((_,i)=>!S.chosen[i]))])];
 if(key==='view')return [item('native:sidebar',S.sidebarVisible?'Seitenleiste ausblenden':'Seitenleiste einblenden','⌘0'),item('native:inspector',S.inspector?'Inspector ausblenden':'Inspector einblenden','⌥⌘0'),null,item('studio:layout-default','Standardlayout','',S.running),item('studio:theater',S.studio.theater?'Viewer verkleinern':'Viewer maximieren','',!['edit','post'].includes(S.view)||S.view==='post'&&S.studio.post==='review'||S.running),item('studio:fullscreen',document.fullscreenElement?'Vollbild verlassen':'Vollbild','',S.running)];
 if(key==='window')return [item('native:project-window',S.name),null,item('studio:activity','Aufträge & Entscheidungen'),item('native:ai-jobs','KI-Aktivitäten'),item('native:export-jobs','Exportaufträge')];
 if(key==='help')return [item('studio:help','NexGenVideo-Hilfe'),item('studio:feedback','Feedback vorbereiten…','',S.running)];
 return [];
}
function drawMenuBar(){
 const bar=$('#nd-menubar');if(!bar.children.length)bar.innerHTML=Object.entries(menuNames).map(([key,name])=>B('native:menu-'+key,name,{attrs:'role="menuitem" aria-haspopup="menu" aria-expanded="false" aria-controls="nd-native-menu"'})).join('');
 for(const button of bar.children){button.disabled=!!S.modal&&S.modal!=='native-menu';button.setAttribute('aria-expanded',String(S.modal==='native-menu'&&activeMenu===button.dataset.do.slice(12)));}
}
chrome=function(){navigationBase.chrome();drawMenuBar();};
function closeNativeMenu(focus=true){if(S.modal!=='native-menu')return;S.modal=null;$('#nd-overlay').innerHTML='';drawMenuBar();if(focus)(menuReturn?.isConnected?menuReturn:$('#nd-menubar [data-do="native:menu-'+activeMenu+'"]'))?.focus({preventScroll:true});}
function showNativeMenu(key){
 if(S.modal&&S.modal!=='native-menu')return;
 if(S.modal==='native-menu'&&activeMenu===key){closeNativeMenu();return;}
 if(S.modal!=='native-menu'){menuReturn=document.activeElement;if(menuReturn?.matches('textarea,input:not([type]),input[type=text],input[type=search]')&&!menuReturn.disabled)menuTextTarget=menuReturn;else if(!menuReturn?.closest('#nd-menubar'))menuTextTarget=null;}activeMenu=key;S.modal='native-menu';dialog();$('#nd-menubar [data-do="native:menu-'+key+'"]')?.focus({preventScroll:true});
}
dialog=function(){
 if(S.modal==='native-menu'){
  drawMenuBar();const anchor=$('[data-do="native:menu-'+activeMenu+'"]'),box=root.getBoundingClientRect(),rect=anchor.getBoundingClientRect();
  $('#nd-overlay').innerHTML=`<section id="nd-native-menu" class="dialog native-menu" role="menu" aria-label="${menuNames[activeMenu]}" style="left:${Math.max(4,Math.min(rect.left-box.left,box.width-314))}px;top:${rect.bottom-box.top+2}px">${menuItems(activeMenu).map(i=>i?B(i.cmd,`<span>${i.checked===undefined?'':'<span class="native-menu-check" aria-hidden="true">'+(i.checked?'✓':'')+'</span>'}${E(i.label)}</span><kbd>${i.shortcut||''}</kbd>`,{disabled:i.disabled,attrs:'role="'+(i.checked===undefined?'menuitem':'menuitemcheckbox')+'" '+(i.checked===undefined?'':'aria-checked="'+i.checked+'" ')+'data-native-command'}):'<hr role="separator">').join('')}</section>`;
  return;
 }
 navigationBase.dialog();drawMenuBar();
 if(S.modal==='studio-help'){
  const list=$('.studio-dialog-body dl');list?.insertAdjacentHTML('afterbegin','<dt>⌘,</dt><dd>App-Einstellungen</dd>');
  $('[data-do="studio:update-check"]')?.remove();
 }
 if(S.modal==='studio-project-settings'){
  $('.studio-dialog')?.classList.add('settings-dialog');const body=$('.studio-dialog-body');body?.classList.add('settings-form');
  body?.insertAdjacentHTML('beforeend',group('Format-Pack',prop('Format',S.pack==='Generic'?'Standard':S.pack)+(S.pack==='Generic'?'':prop('Projektversion',S.studio.packVersion)+SX('pack-recovery','Als Recovery-Kopie aktualisieren…',{cls:'control',disabled:!S.studio.packUpdateAvailable})+'<small>Die gespeicherte Projektversion bleibt bis zu einer ausdrücklichen Aktualisierung erhalten.</small>'),false)+group('Medien & Inhaltssuche',prop('Projektmedien',assets().length+' '+(assets().length===1?'Medium':'Medien'))+settingsRow('',sxCheck('Inhaltssuche aktiv','index',S.studio.index)+SX('index-clear','Inhaltssuche neu aufbauen',{cls:'control'})),false));
 }
 if(S.modal==='studio-settings'&&S.studio.settings==='packs')$('.settings-form').innerHTML=prop('Installiert','Music Video · Demo-Bestand')+settingsRow('',SX('pack-update','Nach Pack-Updates suchen',{cls:'control'})+SX('pack-remove',S.studio.removedVersion?'Unbenutzte Version entfernt':'Unbenutzte Version entfernen',{cls:'control',disabled:S.studio.removedVersion}))+'<small>Installierte Packs gelten appweit. Die Version eines Projekts wird in den Projekteinstellungen verwaltet.</small>';
 if(S.modal==='studio-settings'&&S.studio.settings==='storage')$('.settings-form').innerHTML=prop('Projektordner','Dokumente / NexGenVideo')+prop('Vorschau-Cache',S.studio.cacheCleared?'Leer':'Beispiel-Vorschaudaten')+settingsRow('',SX('cache-clear','Cache leeren',{cls:'control'}))+'<small>Originaldateien bleiben erhalten. Die Inhaltssuche gehört zum jeweiligen Projekt.</small>';
 if(S.modal==='studio-settings'&&S.studio.appNotice)$('.settings-form')?.insertAdjacentHTML('beforeend','<small role="status">'+E(S.studio.appNotice)+'</small>');
 if(S.modal==='search-status')$('.wf-dialog .actions button:first-child')?.remove();
};
action=function(cmd){
 if(cmd.startsWith('native:menu-')){showNativeMenu(cmd.slice(12));return;}
 if(['native:cut','native:copy','native:paste','native:delete','native:select-all'].includes(cmd)){
  if(menuItems('edit').find(i=>i?.cmd===cmd)?.disabled)return;
  const op=cmd.slice(7),el=menuTextTarget?.isConnected?menuTextTarget:null;
  if(el){el.focus({preventScroll:true});if(op==='select-all'){el.select();return;}const start=el.selectionStart,end=el.selectionEnd;if(op==='copy'||op==='cut')textClipboard=el.value.slice(start,end);if(op==='copy')return;el.setRangeText(op==='paste'?textClipboard:'',start,end,'end');el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));return;}
  if(S.view==='board'){if(op==='delete'){action('wf:delete');return;}if(op==='select-all'){S.selected=S.shots.map((_,i)=>i);render();persist();return;}}
  if(op==='select-all'){S.nle.marked=S.nle.clips.map(c=>c.id);S.nle.selected=S.nle.marked[0]||null;S.nle.selectedTitle=null;render();persist();return;}
  if(op==='cut'){studioAction('copy');studioAction('delete');return;}
  studioAction(op);return;
 }
 if(cmd==='native:project-window'){render();$('#nd-title [data-panel="sidebar"]')?.focus();return;}
 if(cmd==='native:ai-jobs'||cmd==='native:export-jobs'){action(cmd==='native:ai-jobs'?'background:ai':'background:export');return;}
 if(cmd==='native:sidebar'||cmd==='native:inspector'){const key=cmd==='native:sidebar'?'sidebarVisible':'inspector';S[key]=!S[key];render();persist();return;}
 if(['create','adopt-import'].includes(cmd)){const prefs=appPreferences();navigationBase.action(cmd);applyAppPreferences(prefs);persist();return;}
 if(cmd==='ux:search-settings'){S.modal='studio-project-settings';dialog();const details=[...$$('.studio-dialog-body details')].find(el=>el.querySelector('[data-sx="index"]'));if(details)details.open=true;return;}
 navigationBase.action(cmd);drawMenuBar();if(cmd==='close')$('[data-do="native:menu-file"]')?.focus({preventScroll:true});
};
studioAction=function(cmd){
 if(['pack-update','pack-remove','cache-clear'].includes(cmd)){if(S.running)return;if(cmd==='pack-update')S.studio.packUpdateAvailable=true;if(cmd==='pack-remove')S.studio.removedVersion=true;if(cmd==='cache-clear')S.studio.cacheCleared=true;S.studio.appNotice={'pack-update':'Beispielupdate verfügbar · Projektversion unverändert','pack-remove':'Unbenutzte Beispielversion entfernt · Projektversion erhalten','cache-clear':'Beispielcache geleert · Originaldateien erhalten'}[cmd];dialog();persist();return;}
 if(cmd==='update-check'){S.modal='native-update';workflowDialog('App-Updates','<p>Die Simulation prüft keinen Update-Server.</p><small>Im Produkt wird der bestehende NexGenVideo-Updater verwendet.</small>',B('close','Schließen',{primary:true}));$('.actions [data-do="close"]')?.remove();drawMenuBar();return;}
 if(cmd.startsWith('open-recent-')){const prefs=appPreferences();navigationBase.studioAction(cmd);applyAppPreferences(prefs);persist();return;}
 navigationBase.studioAction(cmd);
};
restore=function(saved){const prefs=S.studio?appPreferences():null,result=navigationBase.restore(saved);if(result&&prefs)applyAppPreferences(prefs);return result;};
undoContent=function(snapshot){const prefs=appPreferences();navigationBase.undoContent(snapshot);Object.assign(S.studio,prefs);};
task=function(...args){navigationBase.task(...args);if(S.studio.task){S.studio.task.ownerPost=S.view==='post'?S.studio.post:null;renderTask();}};
renderTask=function(){const t=S.studio.task,el=$('#nd-task');if(t&&el&&(t.phase&&t.phase!==S.view||t.ownerPost&&t.ownerPost!==S.studio.post)){el.hidden=true;el.innerHTML='';return;}navigationBase.renderTask();};
render=function(){navigationBase.render();drawMenuBar();};
root.addEventListener('pointerdown',e=>{if(e.target.closest('#nd-menubar')&&S.modal!=='native-menu'){const el=document.activeElement;menuContentTarget=el;menuTextTarget=el?.matches('textarea,input:not([type]),input[type=text],input[type=search]')&&!el.disabled?el:null;}},true);
root.addEventListener('keydown',e=>{
 if(S.modal||S.mediaPreview||e.target.closest('#nd-browser')||/INPUT|TEXTAREA|SELECT/.test(e.target.tagName)||!['edit','post'].includes(S.view))return;
 if((e.metaKey||e.ctrlKey)&&['x','c','v','a'].includes(e.key.toLowerCase())){e.preventDefault();e.stopImmediatePropagation();menuTextTarget=null;menuContentTarget=e.target;action('native:'+{x:'cut',c:'copy',v:'paste',a:'select-all'}[e.key.toLowerCase()]);}
},true);
root.addEventListener('click',e=>{
 const button=e.target.closest('[data-native-command]');if(!button)return;
 const item=menuItems(activeMenu).find(i=>i?.cmd===button.dataset.do);e.stopImmediatePropagation();if(!item||item.disabled)return;
 const cmd=item.cmd;closeNativeMenu(false);action(cmd);drawMenuBar();
},true);
root.addEventListener('pointerdown',e=>{if(S.modal==='native-menu'&&!e.target.closest('#nd-menubar,#nd-native-menu'))closeNativeMenu(false);},true);
root.addEventListener('keydown',e=>{
 if((e.metaKey||e.ctrlKey)&&e.key==='0'&&!S.modal){e.preventDefault();e.stopImmediatePropagation();action(e.altKey?'native:inspector':'native:sidebar');return;}
 if((e.metaKey||e.ctrlKey)&&[',','n','o'].includes(e.key.toLowerCase())){
  if(S.running||S.modal&&S.modal!=='native-menu'&&S.modal!=='studio-settings')return;
  e.preventDefault();e.stopImmediatePropagation();closeNativeMenu(false);action({',':'studio:settings',n:'studio:new',o:'studio:open-project'}[e.key.toLowerCase()]);return;
 }
 if(S.modal!=='native-menu'&&!e.target.closest('#nd-menubar'))return;
 if(e.key==='Escape'){e.preventDefault();e.stopImmediatePropagation();closeNativeMenu();return;}
 if(['ArrowDown','ArrowUp','Home','End'].includes(e.key)){
  e.preventDefault();e.stopImmediatePropagation();if(S.modal!=='native-menu'){showNativeMenu(e.target.dataset.do?.slice(12)||'app');}
  const items=$$('#nd-native-menu button:not(:disabled)'),i=items.indexOf(document.activeElement);
  items[e.key==='Home'?0:e.key==='End'?items.length-1:(i+(e.key==='ArrowUp'?-1:1)+items.length)%items.length]?.focus();
 }
 if(['ArrowLeft','ArrowRight'].includes(e.key)){
  e.preventDefault();e.stopImmediatePropagation();const keys=Object.keys(menuNames),i=keys.indexOf(activeMenu||e.target.dataset.do?.slice(12)),next=keys[(i+(e.key==='ArrowLeft'?-1:1)+keys.length)%keys.length];
  showNativeMenu(next);$('#nd-menubar [data-do="native:menu-'+next+'"]')?.focus();
 }
},true);
