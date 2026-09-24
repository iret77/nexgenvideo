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
 async function click(selector){const p=await run(`const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});if(el.disabled)throw Error('Disabled '+${JSON.stringify(selector)});el.scrollIntoView({block:'nearest'});const b=el.getBoundingClientRect();return{x:b.x+b.width/2,y:b.y+b.height/2}`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p},session);await sleep(50);}
 async function shot(name){const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-studio-'+name+'.png',Buffer.from(image.data,'base64'));}










 const out=here+'/review/'+(process.env.NGV_UI_REVIEW||'refinement-2026-09-20')+'/walkthrough';await mkdir(out,{recursive:true});
 await call('Runtime.enable',{},session);const errors=[];
 chrome.stdio[4].on('data',()=>{});
 const press=async cmd=>{console.log('UI '+cmd);await click('[data-do="'+cmd+'"]');};
 const fill=async(sel,value)=>{await run(`const el=q(${JSON.stringify(sel)});if(!el||el.disabled)throw Error('Unavailable field');el.value=${JSON.stringify(value)};el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));`);};
 const capture=async name=>{const pic=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/'+name+'.png',Buffer.from(pic.data,'base64'));};
 await press('native:menu-file');await press('studio:new');await fill('#nd-name','Erster Film');await fill('#nd-pack','Music Video');await press('create');
 await press('assign-track');await press('assign-lyrics');await press('develop');await press('wf:audio-play');await sleep(300);await press('wf:audio-play');await capture('01-audio');await press('approve');await press('intake-none');
 await fill('#nd-brief-text','Eine kleine Maus hilft einer Stadt. Warm, humorvoll und ohne Gewalt.');await press('approve');await fill('#nd-canvas [data-field="palette"]','Natürlich');await press('approve');await press('develop');
 await press('alternative');await press('ux:goal-Knapper');await press('ux:creative-preview');await press('close');await press('approve');await press('develop');await press('approve');await press('develop');
 await press('mode:animatic');await press('play');await sleep(500);await press('play');await press('mode:board');await test('Übersicht besitzt keinen Animatic-Transport',`return !q('[data-scrub]');`);await press('approve');await press('develop');await press('approve');
 await press('clay:start');await press('clay:derive');await press('clay:review-start');await press('clay:accept');await test('Zweite räumliche Vorlage wird nicht automatisch bestätigt',`return !st().clay.outputs['1E'].accepted&&st().selected[0]===4;`);await press('clay:accept');await press('approve');await press('develop');
 await press('identity-cost');await press('run:identity');await sleep(1450);await test('Identitäten führen unmittelbar zum Ankerauftrag',`return q('#nd-gate').innerText.includes('Shot-Anker vorbereiten');`);await press('anchor-cost');await press('run:anchor');await sleep(2100);
 for(let i=0;i<6;i++){await press('ux:next-anchor');await press('accept-anchor');}
 await press('approve');await press('develop');await press('review-proposal');await press('apply-review-fix');await capture('02-correction-plan');await press('approve');await test('Unverändertes Blocking wird erklärt und bleibt eine ausdrückliche Freigabe',`return st().current==='blocking'&&q('#nd-gate').innerText.includes('unverändert')&&!st().done.blocking;`);await press('approve');await capture('03-correction-anchor');await press('anchor-cost');await press('run:anchor');await sleep(600);await press('ux:next-anchor');await press('accept-anchor');await press('approve');await press('review-run');await press('approve');
 await press('prepare-video');await test('Nur passende Bildbindung ermöglicht Freigabe',`return q('[data-production-model]').value==='Runway|runway/gen4_turbo';`);await press('studio:task-preview');await capture('04-video-order');await press('studio:task-accept');await click('[data-open="board"]');await test('Storyboard bleibt während des Videoauftrags lesbar',`return st().running&&st().view==='board'&&!!q('.contact-sheet')&&q('[data-field="duration"]').disabled;`);await sleep(3300);await click('[data-open="takes"]');
 await click('[data-take]');for(let i=0;i<6;i++)await press('wf:take-select');await test('Sechs Takes ohne sechs Dialoge ausgewählt',`return Object.keys(st().chosen).length===6&&!st().modal&&!!q('.take-screen');`);await capture('05-selected-takes');await press('approve');
 await test('Rohschnitt enthält die gewählte Auswahl',`return st().view==='edit'&&st().nle.clips.filter(c=>c.type!=='audio').length===6;`);
 await press('nle:text');await fill('[data-sx="title-text"]','Erster Film');await press('workspace:post');await press('studio:post-color');await test('Farbe überschreibt keinen Titel',`return q('#nd-inspector').innerText.includes('Videoclip')&&!q('[data-sx="title-text"]');`);await click('[data-sx-clip]');await fill('[data-grade="exposure"]','0.2');await press('studio:post-review');await press('finish:scan');await press('finish:finding-light');await press('finish:accept-finding');await press('finish:confirm-accept');
 await press('finish:mode-cuts');while(await run(`return !q('[data-do="finish:pair-prev"]').disabled`))await press('finish:pair-prev');for(let i=0;i<5;i++){await press('finish:cut-check');if(i<4)await press('finish:pair-next');}await press('finish:mode-film');await press('finish:start');await press('finish:play');await sleep(20500);await click('[data-finish-check="whole"]');await press('finish:record');await press('workspace:finish');await press('finish:export');await press('finish:start-export');await sleep(1500);
 await test('Export übernimmt vollständige Sequenz und Prüfung',`return st().finish.exports.at(-1)?.status==='complete'&&st().finish.exports.at(-1).review&&st().finish.exports.at(-1).duration===20;`);await capture('06-export');
 await press('workspace:media');await click('[data-do^="asset:"]');await press('pool:new');await fill('#nd-folder-name','Auswahl');await press('pool:save-folder');await test('Neuer leerer Ordner hat keine unsichtbare Auswahl',`return !st().mediaSelection&&!st().mediaMarked.length&&!q('[data-do="studio:asset-delete"]');`);await capture('07-empty-folder');
 results.push({name:'Keine unbehandelten Browserfehler',pass:runtimeErrors.length===0,errors:runtimeErrors});await writeFile(out+'/checks.json',JSON.stringify(results,null,2));console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,total:results.length}));if(results.some(x=>!x.pass))process.exitCode=1;
}catch(e){console.error(e);process.exitCode=1;await writeFile(here+'/review/refinement-2026-09-20/walkthrough-error.json',JSON.stringify({error:e.message,state:await evalJS(`document.getElementById('ngv-desk').ngvTest.state()`).catch(()=>null)},null,2));}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}
