import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir, rm} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here=path.dirname(fileURLToPath(import.meta.url));
const chrome=spawn(process.env.CHROME_BIN||'google-chrome',['--headless=new','--user-data-dir='+path.join(here,'review','.browser-'+process.pid),'--no-sandbox','--disable-gpu','--no-first-run','--remote-debugging-pipe','--window-size=1048,980','about:blank'],{stdio:['ignore','ignore','inherit','pipe','pipe']});
let next=0,buffer='',session;const pending=new Map();
chrome.stdio[4].on('data',chunk=>{buffer+=chunk.toString();let idx;while((idx=buffer.indexOf('\0'))>=0){const msg=JSON.parse(buffer.slice(0,idx));buffer=buffer.slice(idx+1);if(msg.method==='Inspector.targetCrashed'||msg.method==='Target.targetCrashed')console.error(JSON.stringify(msg));if(msg.method==='Runtime.exceptionThrown')runtimeErrors.push(msg.params.exceptionDetails);if(pending.has(msg.id)){const {resolve,reject}=pending.get(msg.id);pending.delete(msg.id);msg.error?reject(Error(JSON.stringify(msg.error))):resolve(msg.result);}}});
function call(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});chrome.stdio[3].write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0');});}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const evalJS=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},session);if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
const deadline=setTimeout(()=>{chrome.kill();process.exitCode=1;console.error('Browser check timed out');},120000);
const results=[],runtimeErrors=[];
try {
 console.log('Browser starting',chrome.pid);await call('Browser.getVersion');console.log('Browser ready'); const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Schnitt'});session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;console.log('Target attached');await call('Runtime.enable',{},session);await sleep(600);console.log('Page loaded');
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 const setup=`const r=document.getElementById('ngv-desk'),a=r.ngvTest,q=s=>r.querySelector(s),st=()=>a.state();`;
 const run=code=>evalJS(`(()=>{${setup}${code}})()`);
 async function test(name,code){console.log('CHECK '+name);try{const pass=await run(code);results.push({name,pass:!!pass});console.log((pass?'PASS ':'FAIL ')+name);}catch(e){results.push({name,pass:false,error:e.message.slice(0,1200)});console.log('ERROR '+name+' '+e.message.slice(0,500));}}
 const change=(selector,value)=>run(`{const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.value=${JSON.stringify(String(value))};el.dispatchEvent(new Event('change',{bubbles:true}));}`);
 async function click(selector){const p=await run(`const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.scrollIntoView({block:'nearest'});const b=el.getBoundingClientRect();return{x:b.x+b.width/2,y:b.y+b.height/2}`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p},session);await sleep(50);}
 async function shot(name){const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-studio-'+name+'.png',Buffer.from(image.data,'base64'));}










 const out=path.join(here,'review',process.env.NGV_UI_REVIEW||'navigation-2026-09-20');await mkdir(out,{recursive:true});
 const capture=async name=>{const p=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(path.join(out,name+'.png'),Buffer.from(p.data,'base64'));};
 const press=async cmd=>click((await run(`return !!q('#nd-native-menu [data-do="${cmd}"]');`)?'#nd-native-menu ':'')+'[data-do="'+cmd+'"]');
 const key=async(key,code,modifiers=0)=>{await call('Input.dispatchKeyEvent',{type:'keyDown',key,code,modifiers},session);await call('Input.dispatchKeyEvent',{type:'keyUp',key,code,modifiers},session);};
 const inventory=[];
 await test('Systemmenüleiste liegt außerhalb des Projektfensters',`return q('#nd-menubar').parentElement===r&&!q('.app-window').contains(q('#nd-menubar'))&&q('#nd-title').closest('.app-window')!==null&&q('#nd-title').getBoundingClientRect().top-q('#nd-menubar').getBoundingClientRect().bottom>=8;`);
 await run(`a.fixture('Schnitt');a.nleSeek(1,false);a.render();`);await press('native:menu-edit');await capture('edit-menu');
 await test('Schnittbefehle und Standardbearbeitung sind vorhanden',`return ['cut','copy','paste','delete','select-all'].every(k=>!!q('[data-do="native:'+k+'"]'))&&!q('[data-do="nle:split"]').disabled&&!q('[data-do="nle:trim-in"]').disabled;`);
 const clipCount=await run(`return st().nle.clips.length;`);await press('nle:split');
 await test('Teilen aus dem Menü erstellt echte Timeline-Instanz',`return st().nle.clips.length===${clipCount}+1;`);await run(`a.action('undo');`);
 await press('native:menu-edit');await press('native:cut');
 await test('Ausschneiden entfernt die Auswahl und erhält sie in der Zwischenablage',`return st().nle.clips.length===${clipCount}-1&&st().studio.clipboard.length===1;`);
 await press('native:menu-edit');await press('native:paste');
 await test('Einsetzen erstellt Clip mit neuer Instanz-ID',`return st().nle.clips.length===${clipCount}&&st().nle.selected!==st().studio.clipboard[0].id;`);
 await run(`const c=st().nle.clips.find(c=>c.id===st().nle.selected);a.action('studio:track-lock-'+c.track);`);await press('native:menu-edit');
 await test('Gesperrte Spur blockiert Ausschneiden, Einsetzen und Teilen',`return ['native:cut','native:paste','nle:split'].every(k=>q('[data-do="'+k+'"]').disabled);`);await key('Escape','Escape');
 await run(`a.fixture('Schnitt');a.action('workspace:post');`);await press('native:menu-edit');
 await test('Postproduction bietet keine aktiven Montagebefehle',`return ['native:cut','native:paste','nle:split','nle:trim-in'].every(k=>q('[data-do="'+k+'"]').disabled);`);await key('Escape','Escape');
 await run(`a.fixture('Leer','Generic');a.editField({dataset:{field:'briefText'},value:'Eine Maus rettet die Stadt.'});a.render();const input=q('[data-field="briefText"]');input.focus();input.setSelectionRange(5,9);`);
 await press('native:menu-edit');await press('native:copy');
 await test('Kopieren aus Textfeld verändert keinen Projektinhalt',`return st().docs.brief==='Eine Maus rettet die Stadt.';`);
 await run(`const input=q('[data-field="briefText"]');input.focus();input.setSelectionRange(0,4);`);await press('native:menu-edit');await press('native:paste');
 await test('Einsetzen im Textfeld ersetzt exakt die Textauswahl',`return st().docs.brief==='Maus Maus rettet die Stadt.';`);
 await run(`a.fixture('Schnitt');`);await press('native:menu-window');await press('native:ai-jobs');
 await test('Fenstermenü öffnet vorhandene KI-Aktivitätsanzeige',`return !q('#nd-background').hidden&&q('#nd-background').innerText.includes('KI');`);await press('background:close');

 await test('Abbrechen eines Projektdialogs gibt Fokus an Ablage zurück',`a.action('studio:new');a.action('close');return document.activeElement===q('[data-do="native:menu-file"]');`);
 for(const [mode,name]of [['media','Medien'],['production','Produktion'],['edit','Schnitt'],['post','Postproduction'],['finish','Export']]){
  await run(`a.fixture('Schnitt');a.action('workspace:${mode}');`);
  await test(name+': Sidebar enthält keine App- oder Projektverwaltung',`return !q('#nd-browser').innerText.match(/Einstellungen|Aufträge & Entscheidungen|Hilfe|Fenster &/);`);
  await test(name+': App-Menü öffnet Einstellungen',`q('[data-do="native:menu-app"]').click();q('#nd-native-menu [data-do="studio:settings"]').click();return st().modal==='studio-settings'&&q('[data-sx="uiScale"]')!==null;`);
  await press('studio:modal-close');await press('native:menu-file');
  await test(name+': Projektname ist Text, Projektaktionen liegen unter Ablage',`const t=q('#nd-native-menu').innerText,n=q('.project-title');return n.tagName==='SPAN'&&!n.querySelector('button,svg')&&!q('[data-do="project"]')&&t.includes('Projekteinstellungen')&&!!q('#nd-native-menu [data-do="studio:new"]')&&!!q('#nd-native-menu [data-do="studio:open-project"]')&&!!q('#nd-native-menu [data-do="studio:save-project"]')&&!!q('#nd-native-menu [data-do="studio:save-copy"]');`);
  await key('Escape','Escape');await press('native:menu-window');await test(name+': Fenster zeigt Projekt und Aktivitäten',`return q('#nd-native-menu').innerText.includes(st().name)&&!!q('#nd-native-menu [data-do="studio:activity"]');`);await key('Escape','Escape');await capture(mode);
  inventory.push(await run(`return {workspace:'${name}',sidebar:q('#nd-browser').innerText,toolbar:q('#nd-surface-tools').innerText,inspector:q('#nd-inspector').innerText,actions:[...r.querySelectorAll('button')].filter(e=>e.getBoundingClientRect().height>0).map(e=>({name:e.getAttribute('aria-label')||e.innerText,action:e.dataset.do,disabled:e.disabled}))};`));
 }
 await run(`a.fixture('Blocking');`);await press('native:menu-app');await capture('app-menu');await test('App-Menü liegt vollständig über der Arbeitsfläche',`const b=q('#nd-native-menu [data-do="studio:update-check"]'),bounds=b.getBoundingClientRect();return b.contains(document.elementFromPoint(bounds.x+bounds.width/2,bounds.y+bounds.height/2));`);await press('studio:settings');await capture('settings');
 await test('Offene Dialoge werden nicht durch Menüwechsel verworfen',`return [...q('#nd-menubar').querySelectorAll('button')].every(b=>b.disabled);`);
 await press('studio:modal-close');await press('native:menu-file');await key('ArrowDown','ArrowDown');
 await test('Menü ist mit Pfeiltasten erreichbar',`return document.activeElement.closest('#nd-native-menu')!==null;`);
 await key('Escape','Escape');await test('Escape schließt Menü und stellt den Fokus wieder her',`return !st().modal&&!!document.activeElement.closest('#nd-menubar');`);
 await key(',','Comma',4);await test('⌘, öffnet App-Einstellungen',`return st().modal==='studio-settings';`);await press('studio:modal-close');
 await press('native:menu-view');await press('native:inspector');await test('Darstellungsmenü schaltet denselben Inspector wie das Pane-Icon',`return !st().inspector&&q('[data-panel="inspector"]').getAttribute('aria-pressed')==='false';`);
 await click('[data-panel="inspector"]');
 await test('Pane-Icon stellt Inspector ohne Arbeitsraumwechsel wieder her',`return st().inspector&&st().view==='blocking';`);
 await run(`a.fixture('Leer','Generic');a.editField({dataset:{field:'briefText'},value:'Die Maus hilft der Stadt.'});`);
 await press('native:menu-edit');await test('Bearbeiten-Menü zeigt Undo und Redo mit korrekter Verfügbarkeit',`return !q('[data-do="undo"]').disabled&&q('[data-do="redo"]').disabled;`);
 await press('undo');await press('native:menu-edit');await test('Nach Undo wird Redo verfügbar',`return !q('[data-do="redo"]').disabled&&st().docs.brief==='';`);await press('redo');
 await test('Redo stellt denselben Inhalt wieder her',`return st().docs.brief==='Die Maus hilft der Stadt.';`);
 await run(`a.action('studio:settings-providers');`);await click('[data-sx="provider-Runway"]');await press('studio:modal-close');
 await press('native:menu-file');await press('studio:new');await change('#nd-name','Zweites Projekt');await change('#nd-pack','Generic');await press('create');
 await test('Neues Projekt setzt App-Anbieter nicht zurück',`return st().name==='Zweites Projekt'&&!st().studio.providers.Runway;`);
 await run(`a.editField({dataset:{field:'briefText'},value:'Eine neue Geschichte.'});a.action('undo');`);
 await test('Projekt-Undo setzt App-Einstellungen nicht zurück',`return !st().studio.providers.Runway;`);
 await run(`a.action('studio:settings-packs');`);await test('App-Packverwaltung enthält keine Projektmigration',`return !q('[data-do="studio:pack-recovery"]')&&q('[data-do="studio:pack-update"]')!==null;`);await press('studio:modal-close');
 await run(`a.fixture('Blocking');a.action('studio:settings-packs');`);const version=await run(`return st().studio.packVersion;`);await press('studio:pack-update');
 await test('Katalogprüfung verändert keine Projektversion',`return st().studio.packVersion===${JSON.stringify(version)}&&st().studio.packUpdateAvailable;`);
 await press('studio:modal-close');await press('native:menu-file');await press('studio:project-settings');await capture('project-settings');
 await test('Projektmigration ist ausdrücklich in Projekteinstellungen erreichbar',`return q('[data-do="studio:pack-recovery"]')!==null&&q('[data-sx="index"]')!==null&&!q('[data-sx="provider-Runway"]');`);
 await press('studio:modal-close');await run(`a.action('studio:settings-storage');`);
 await test('App-Speicher enthält keine projektbezogene Index-Schaltung',`return q('[data-do="studio:cache-clear"]')!==null&&!q('[data-sx="index"]');`);await press('studio:modal-close');
 await run(`a.action('workspace:media');a.action('studio:index');a.action('ux:search-settings');`);
 await test('Inhaltssuche führt zur geöffneten Projekteinstellung',`return st().modal==='studio-project-settings'&&q('[data-sx="index"]').closest('details').open;`);await press('studio:modal-close');
 await run(`a.fixture('Schnitt');a.action('studio:color-match');`);
 await test('KI-Auftrag erscheint beim zuständigen Arbeitsraum',`return st().studio.task&&q('#nd-task').hidden===false;`);await run(`a.action('workspace:production');`);
 await test('Schnittauftrag erscheint nicht in Produktion',`return q('#nd-task').hidden;`);await run(`a.action('workspace:edit');`);
 await test('Rückkehr erhält den unbestätigten Auftrag',`return !q('#nd-task').hidden&&st().studio.task.stage==='prepare';`);await press('studio:task-close');
 await run(`a.action('workspace:post');a.action('studio:color-match');a.action('studio:post-audio');`);
 await test('Farbauftrag erscheint nicht beim Tonwerkzeug',`return q('#nd-task').hidden;`);await run(`a.action('studio:post-color');`);
 await test('Farbauftrag bleibt beim zuständigen Werkzeug erreichbar',`return !q('#nd-task').hidden;`);await press('studio:task-close');
 await run(`a.action('studio:save-project');a.action('workspace:media');a.action('studio:activity');`);
 await test('Verlauf verspricht keine erneute Ausführung',`return !q('[data-do^="studio:activity-repeat-"]')&&q('[data-do^="studio:activity-show-"]')!==null;`);
 await press('studio:activity-show-0');await test('Verlauf zeigt Arbeitsbereich ohne neuen KI-Auftrag',`return st().view==='post'&&!st().studio.task;`);
 await run(`a.fixture('Leer','Generic');a.action('open:takes');`);await test('Leerer Take-Inspector enthält keine Projektverwaltung',`return !q('#nd-inspector').innerText.includes('Projekteinstellungen');`);
 await run(`a.fixture('Schnitt');a.action('workspace:post');a.action('studio:title-add');`);
 const titleText=await run(`return st().nle.titles[0].text;`);
 await run(`a.action('studio:post-captions');`);await test('Untertitel-Korrektur ist ohne Untertitel deaktiviert',`return q('[data-do="studio:caption-correct"]').disabled;`);
 await press('studio:captions');await press('studio:task-preview');await press('studio:task-accept');await press('studio:task-close');
 await test('Untertitelbearbeitung zeigt keine Film-Titel',`return !!q('#nd-inspector [data-do="studio:title-1"]')&&!q('#nd-inspector [data-do="studio:title-0"]')&&!q('[data-do="studio:post-titles"]:not(.tree-row)');`);
 await press('studio:title-1');await change('[data-sx="title-text"]','Ein korrigierter Untertitel.');
 await test('Untertitel bleibt bei Untertiteln und verändert keinen Film-Titel',`return st().studio.post==='captions'&&st().nle.titles[1].text==='Ein korrigierter Untertitel.'&&q('#nd-canvas').innerText.includes('Ein korrigierter Untertitel.')&&st().nle.titles[0].text===${JSON.stringify(titleText)};`);
 await capture('captions');await press('studio:post-titles');await test('Titelbereich zeigt nur Film-Titel',`return !!q('#nd-inspector [data-do="studio:title-0"]')&&!q('#nd-inspector [data-do="studio:title-1"]');`);
 await run(`a.action('workspace:production');`);await test('Montageauftrag ist aus der Produktionsfläche entfernt',`return !q('#nd-inspector [data-do="studio:assembly"]');`);
 await run(`a.action('workspace:edit');`);await press('native:menu-edit');await test('Montagefunktion bleibt im Schnitt bedienbar',`return !q('[data-do="studio:assembly"]').disabled;`);await press('studio:assembly');
 const clips=await run(`return st().nle.clips.length;`);await press('studio:task-preview');await press('studio:task-accept');
 await test('Montage erhält bestehende Clips und legt zusätzliche Spur an',`return st().nle.clips.length===${clips}+6;`);await press('studio:task-close');
 for(const phase of ['audio','brief','design','treatment','script','board','plan','blocking','refs','review','takes']){
  await run(`a.fixture('Schnitt');a.action('open:${phase}');`);
  inventory.push(await run(`return {phase:'${phase}',sidebar:q('#nd-browser').innerText,toolbar:q('#nd-surface-tools').innerText,inspector:q('#nd-inspector').innerText,task:q('#nd-task')?.innerText};`));
 }
 await run(`a.fixture('Blocking');`);for(const width of [1440,1048,768,390,320]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false},session);await sleep(80);
  await test('Menüleiste passt bei '+width+' px',`const m=q('#nd-menubar');return m.scrollWidth<=m.clientWidth&&[...m.children].every(b=>b.getBoundingClientRect().right<=r.getBoundingClientRect().right);`);
  if(width===1048)await capture('production-final');
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 await writeFile(path.join(out,'inventory.json'),JSON.stringify(inventory,null,2));
 results.push({name:'Keine unbehandelten Browserfehler',pass:runtimeErrors.length===0,errors:runtimeErrors});await writeFile(path.join(out,'checks.json'),JSON.stringify(results,null,2));console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,total:results.length}));if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}
