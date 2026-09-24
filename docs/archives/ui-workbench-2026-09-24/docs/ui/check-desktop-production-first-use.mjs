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










 const out=here+'/review/'+(process.env.NGV_UI_REVIEW||'refinement-2026-09-20')+'/interactions';await mkdir(out,{recursive:true});
 await call('Runtime.enable',{},session);const errors=[];
 chrome.stdio[4].on('data',()=>{});
 await test('Prüfen bestätigt keine Clay-Vorlage',`a.fixture('Blocking');a.action('clay:derive');a.action('clay:review-start');return Object.values(st().clay.outputs).every(o=>!o.accepted)&&st().selected[0]===0;`);
 await test('Bestätigen gilt nur der sichtbaren Vorlage und führt weiter',`a.action('clay:accept');return st().clay.outputs['1A'].accepted&&!st().clay.outputs['1E'].accepted&&st().selected[0]===4;`);
 await test('Blocking-Gate bleibt bis letzter Bestätigung gesperrt',`const blocked=!a.readiness();a.action('clay:accept');return blocked&&a.readiness();`);
 await test('Veränderte Geometrie entwertet Sichtung weiterhin',`a.action('clay:view-space');a.action('clay:object-engine');const e=q('[data-clay-field="object-x"]');e.value='4';e.dispatchEvent(new Event('change',{bubbles:true}));return !a.readiness();`);
 await test('Korrektur bleibt bei Shot 1E und zeigt Zustände direkt',`a.fixture('Review');a.action('review-proposal');a.action('apply-review-fix');return st().correction.shotID==='1E'&&st().shots[st().selected[0]].id==='1E'&&q('[data-field="stateIn"]').closest('details').open;`);
 await test('Unveränderter Skip führt zur gezielten Ankerkorrektur',`a.action('approve');return st().current==='refs'&&st().selected[0]===4&&st().refMode==='anchors'&&q('#nd-gate').innerText.includes('Betroffene Anker');`);
 await test('Korrektur bewahrt andere Ankersichtungen',`return st().anchorAccepted.length===5&&st().clay.staleAnchorIds.join()==='1E';`);
 await test('Kostendialog benennt einen Shot und ist folgenlos abbrechbar',`const before=JSON.stringify([st().anchorInputs,st().cost]);a.action('anchor-cost');const text=q('.dialog').innerText;a.action('close');return text.includes('1 betroffener Shot')&&before===JSON.stringify([st().anchorInputs,st().cost]);`);
 await test('Takes prüfen öffnet dauerhaftes Arbeitsfenster',`a.fixture('Takes');let s=st();s.chosen={};a.restore(s);a.action('studio:take-review');return !st().modal&&!!q('.take-screen')&&!!q('#nd-browser');`);
 await test('Take auswählen führt zum nächsten offenen Shot',`a.action('wf:take-select');return st().chosen[0]===1&&st().selected[0]===1&&!!q('.take-screen');`);
 await test('Direkte Shotnavigation vergibt keine Freigabe',`a.action('ux:take-shot-4');return st().selected[0]===4&&Object.keys(st().chosen).length===1;`);
 await test('Take-Befund braucht eine bewusste Ausnahme',`a.action('wf:take-2');a.action('wf:take-select');return !st().chosen[4]&&q('[data-do="wf:take-select"]').disabled;`);
 await test('Ausnahme bleibt am konkreten Take dokumentiert',`const e=q('[data-wf="take-note"]');e.value='Hand außerhalb des gewählten Schnittbereichs';e.dispatchEvent(new Event('input',{bubbles:true}));a.action('wf:take-select');return st().chosen[4]===2&&st().studio.takeReviews['4-2'].override;`);
 await test('Take-Übersicht bleibt direkt erreichbar',`a.action('wf:take-overview');return !st().takeViewer&&!!q('.take-board-row');`);
 await test('Farbe zeigt nach Titel keine Titel-Regler',`a.fixture('Schnitt');a.action('nle:text');a.action('workspace:post');a.action('studio:post-color');return !q('[data-sx="title-text"]')&&q('#nd-inspector').innerText.includes('Videoclip');`);
 await test('Werkzeugwechsel verändert weder Titel noch ausgewählte Quelle',`const before=st().nle.selectedTitle;a.action('studio:post-audio');return st().nle.selectedTitle===before&&!q('[data-sx="title-text"]');`);
 await test('Videoclip-Auswahl öffnet passende Farbwerkzeuge',`a.action('studio:post-color');a.nleSelect(st().nle.clips.find(c=>c.type!=='audio').id);return !!q('[data-grade="exposure"]')&&st().studio.post==='color';`);
 await test('Titelfunktion bleibt vollständig erreichbar',`a.action('studio:post-titles');return !!q('[data-sx="title-text"]');`);
 await test('Untertitel sind sequenzbezogen ohne Videoclip erreichbar',`a.action('studio:post-captions');return !!q('[data-do="studio:captions"]')&&!q('[data-sx="title-text"]');`);
 await test('Ordnerwechsel entfernt unsichtbare Auswahl',`a.fixture('Medien');a.action('pool:folder-documents');return !st().mediaMarked.length&&!st().mediaSelection&&!q('[data-do="studio:asset-delete"]');`);
 await test('Suche entfernt unsichtbare Auswahl und Aktionen',`a.action('pool:folder-all');q('[data-do^="asset:"]').click();const e=q('[data-media-search]');e.value='XYZ-unbekannt';e.dispatchEvent(new Event('input',{bubbles:true}));return !st().mediaSelection&&!q('[data-do="studio:asset-delete"]');`);
 await test('Ansichtswechsel bewahrt sichtbare Auswahl',`a.action('pool:clear');q('[data-do^="asset:"]').click();const id=st().mediaSelection;a.action('pool:view-list');return st().mediaSelection===id&&st().mediaMarked.includes(id);`);
 await test('Inhaltssuche erklärt Nutzen statt direkt Speicher zu öffnen',`a.action('studio:index');return q('.dialog').innerText.includes('Motive')&&st().modal==='search-status';`);
 await test('Wartung bleibt ausdrücklich erreichbar',`a.action('ux:search-settings');return st().modal==='studio-project-settings'&&!!q('[data-do="studio:index-clear"]');`);
 await test('Modellprüfung zeigt konkretes Modell und Grenzen',`a.action('studio:model-research');return !!q('[data-research-model]')&&!q('.dialog input[type="checkbox"]')&&q('.dialog').innerText.includes('Nicht belegt');`);
 await test('Kreative Richtung wird vor dem Vorschlag gewählt',`a.fixture('Leer','Generic');a.editField({dataset:{field:'briefText'},value:'Eine Maus hilft der Stadt.'});a.action('approve');a.action('approve');a.action('develop');a.action('alternative');a.action('ux:goal-Knapper');return st().creative.stage==='prepare'&&st().creative.goal==='Knapper';`);
 await test('Vorschlag und Abbruch verändern das Dokument nicht',`const old=st().docs.treatment[0];a.action('ux:creative-preview');const shorter=st().creative.result.length<old.length;a.action('close');return shorter&&st().docs.treatment[0]===old;`);
 await test('Übernahme ändert nur den gewählten Abschnitt und hat Undo',`a.action('segment:1');a.action('alternative');a.action('ux:goal-Mehr Spannung');a.action('ux:creative-preview');const before=st().docs.treatment,proposed=st().creative.result;a.action('ux:creative-apply');const valid=st().docs.treatment[1]===proposed&&st().docs.treatment[0]===before[0];a.action('undo');return valid&&JSON.stringify(st().docs.treatment)===JSON.stringify(before);`);
 await test('Gestaltung ist in der Hauptfläche bedienbar',`a.fixture('Leer','Generic');a.editField({dataset:{field:'briefText'},value:'Test mit Gestaltung.'});a.action('approve');return !!q('#nd-canvas [data-field="style"]')&&!q('#nd-inspector [data-field="style"]');`);
 await test('Modellwahl und reale Renderdauer sind im Auftrag sichtbar',`a.fixture('Takes');a.action('revise');a.action('confirm-rewind');a.action('video-cost');q('.wf-order-details').open=true;return !!q('[data-production-model]')&&q('.wf-order-details').innerText.includes('5 s Render');`);
 await test('Modell ohne Bildbindung kann bestätigte Anker nicht ignorieren',`const e=q('[data-production-model]');e.value='fal.ai|bytedance/seedance-2.0/text-to-video';e.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:task-preview');return st().studio.task.stage==='prepare'&&q('[data-do="studio:task-preview"]').disabled;`);
 await test('Kosten binden Modell, Shots, Renderdauer und Eingaben',`const e=q('[data-production-model]');e.value='Runway|runway/gen4_turbo';e.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:task-preview');const t=st().studio.task;return t.stage==='review'&&t.cost===3&&t.quote.rows.length===6&&t.quote.rows[0].planned===3&&t.quote.rows[0].duration===5;`);
 await test('Modellwechsel verwirft frühere Kostenfreigabe',`const e=q('[data-production-model]');e.value='fal.ai|bytedance/seedance-2.0/text-to-video';e.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:task-accept');return !st().running&&!st().studio.task.quote;`);
 await change('[data-production-model]','Runway|runway/gen4_turbo');await run(`a.action('studio:task-preview');a.action('studio:task-accept');`);
 await test('Hintergrundarbeit erlaubt Sichtung aber keine Bearbeitung',`const nav=q('[data-open="board"]');if(nav.disabled)return false;nav.click();const immutable=q('[data-field="duration"]').disabled;const phase=st().current;a.action('revise');return st().view==='board'&&immutable&&!st().modal&&st().current===phase;`);
 await sleep(3300);
 await test('Job endet auch beim Sichten einer anderen Phase',`return !st().running&&st().view==='board'&&Object.values(st().takes).flat().length===6&&Object.keys(st().productionReceipts).length===6;`);
 await test('Pane-Größen bleiben nach dem Auftrag bedienbar',`return [...r.querySelectorAll('[data-resize]')].every(e=>!e.disabled);`);
 await test('Budget entspricht freigegebenem Auftrag',`return st().studio.task.cost===3&&st().cost===8.98;`);

 await test('Fal-only kann mit der vorhandenen Seedance-Bildroute produzieren',`a.fixture('Takes');a.action('revise');a.action('confirm-rewind');a.action('studio:settings-providers');let field=q('[data-sx="provider-Runway"]');field.checked=false;field.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:modal-close');a.action('video-cost');a.action('studio:task-preview');return st().studio.task.quote.provider==='fal.ai'&&!q('[data-do="studio:task-accept"]').disabled;`);
 await test('Deaktivierter Anbieter entwertet bestehende Kostenfreigabe',`a.action('studio:settings-providers');let field=q('[data-sx="provider-fal.ai"]');field.checked=false;field.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:modal-close');a.action('studio:task-accept');return !st().running&&q('[data-do="studio:task-accept"]').disabled;`);
 await test('Seedance 2.5 bindet längere Renderdauer ohne Shot-Timing zu ändern',`a.fixture('Takes');a.action('revise');a.action('confirm-rewind');a.action('video-cost');const e=q('[data-production-model]');e.value='fal.ai|bytedance/seedance-2.5/image-to-video';e.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:task-preview');return st().studio.task.quote.rows[0].duration===4&&st().shots[0].duration===3;`);
 await test('Unabhängige Revision beendet früheren Korrekturkontext',`a.fixture('Review');a.action('review-proposal');a.action('apply-review-fix');a.action('open:board');a.action('revise');a.action('confirm-rewind');return !st().correction&&st().current==='board';`);

 await test('Weiterer Take verwendet dieselbe Modell- und Kostenentscheidung',`a.fixture('Takes');a.action('studio:take-review');a.action('retake-cost');a.action('studio:task-preview');return st().studio.task.retake&&st().studio.task.quote.rows.length===1&&st().studio.task.cost===.5;`);
 await run(`a.action('studio:task-accept');`);await sleep(1200);
 await test('Weitere Variante erhält Vorgänger und bewusste Auswahl',`return st().takes[0].join()==='1,2,3'&&st().chosen[0]===1&&st().productionReceipts['1A~3'].provider==='Runway';`);
 for(const [name,code]of [['takes',`a.fixture('Takes');a.action('studio:take-review');`],['design',`a.fixture('Leer','Generic');a.editField({dataset:{field:'briefText'},value:'Eine Maus hilft der Stadt.'});a.action('approve');`],['creative',`a.action('approve');a.action('develop');a.action('alternative');a.action('ux:creative-preview');`],['model',`a.fixture('Takes');a.action('revise');a.action('confirm-rewind');a.action('video-cost');a.action('studio:task-preview');`]]){await run(code);await sleep(100);const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/'+name+'.png',Buffer.from(image.data,'base64'));}

 const fragment=await readFile('<local home>/.codex/visualizations/2026/09/12/01a0956c-ab36-7ed3-b838-cf38a6f4b3b7/nexgenvideo-desktop-workbench.html','utf8');
 const inlineFile=path.join(out,'inline-preview.html');await writeFile(inlineFile,'<!doctype html><html lang="de"><meta charset="utf-8"><body style="margin:12px;background:#141518">'+fragment+'</body></html>');
 await call('Page.navigate',{url:pathToFileURL(inlineFile).href},session);await sleep(600);
 await test('Ausgelieferte Inline-Vorschau lädt ohne Bootfehler',`return !!a&&q('#nd-browser').innerText.includes('Blocking');`);
 await test('Inline-Vorschau besitzt den neuen Take-Viewer',`a.fixture('Takes');a.action('studio:take-review');return !!q('.take-screen')&&!st().modal;`);
 await call('Emulation.setDeviceMetricsOverride',{width:768,height:1000,deviceScaleFactor:1,mobile:false},session);await sleep(100);
 await test('Inline-Take-Viewer bleibt im Fenster',`const b=r.getBoundingClientRect(),c=q('#nd-canvas').getBoundingClientRect(),d=q('.take-screen-decision').getBoundingClientRect();return r.scrollWidth<=r.clientWidth+1&&d.right<=c.right+1&&d.bottom<=b.bottom;`);
 await rm(inlineFile,{force:true});
 results.push({name:'Keine unbehandelten Browserfehler',pass:runtimeErrors.length===0,errors:runtimeErrors});await writeFile(out+'/checks.json',JSON.stringify(results,null,2));console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,total:results.length}));if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}
