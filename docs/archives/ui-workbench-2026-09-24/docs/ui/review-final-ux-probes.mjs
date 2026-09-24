import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here=path.dirname(fileURLToPath(import.meta.url));
const chrome=spawn(process.env.CHROME_BIN||'google-chrome',['--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--no-first-run','--remote-debugging-pipe','--window-size=1048,980','about:blank'],{stdio:['ignore','ignore','ignore','pipe','pipe']});
let next=0,buffer='',session;const pending=new Map();
chrome.stdio[4].on('data',chunk=>{buffer+=chunk.toString();let idx;while((idx=buffer.indexOf('\0'))>=0){const msg=JSON.parse(buffer.slice(0,idx));buffer=buffer.slice(idx+1);if(pending.has(msg.id)){const {resolve,reject}=pending.get(msg.id);pending.delete(msg.id);msg.error?reject(Error(JSON.stringify(msg.error))):resolve(msg.result);}}});
function call(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});chrome.stdio[3].write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0');});}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const evalJS=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},session);if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
const deadline=setTimeout(()=>{chrome.kill();process.exitCode=1;console.error('Browser check timed out');},90000);
const results=[];
try {
 await call('Browser.getVersion'); const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Schnitt'});session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;await sleep(600);
 await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false},session);
 const setup=`const r=document.getElementById('ngv-desk'),a=r.ngvTest,q=s=>r.querySelector(s),st=()=>a.state();`;
 const run=code=>evalJS(`(()=>{${setup}${code}})()`);
 async function test(name,code){try{const pass=await run(code);results.push({name,pass:!!pass});console.log((pass?'PASS ':'FAIL ')+name);}catch(e){results.push({name,pass:false,error:e.message.slice(0,1200)});console.log('ERROR '+name+' '+e.message.slice(0,500));}}
 const change=(selector,value)=>run(`{const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.value=${JSON.stringify(String(value))};el.dispatchEvent(new Event('change',{bubbles:true}));}`);
 async function click(selector){const p=await run(`const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.scrollIntoView({block:'nearest'});const b=el.getBoundingClientRect();return{x:b.x+b.width/2,y:b.y+b.height/2}`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p},session);await sleep(50);}
 async function shot(name){const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-studio-'+name+'.png',Buffer.from(image.data,'base64'));}









 const out=here+'/review/final-ux-2026-09-19';await mkdir(out,{recursive:true});
 await call('Page.bringToFront',{},session);await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 const findings=[];
 async function observe(name,code,screenshot=true){const result=await run(code);findings.push({name,...result});console.log(JSON.stringify({name,...result}));if(screenshot){await sleep(120);const img=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/probe-'+name+'.png',Buffer.from(img.data,'base64'));}}
 await observe('cancel-renewal',`a.fixture('References');a.action('open:blocking');a.action('revise');a.action('confirm-rewind');a.action('clay:start');a.action('clay:derive');for(let i=0;i<6;i++){a.action('clay:output-'+i);a.action('clay:accept');}a.action('approve');const before={anchors:st().anchors,count:st().anchorCount,cost:st().cost};a.action('clay:renew-anchors');const during={anchors:st().anchors,count:st().anchorCount,modal:st().modal};a.action('close');return {before,during,after:{anchors:st().anchors,count:st().anchorCount,cost:st().cost,modal:st().modal},screen:q('#nd-canvas').innerText}`);
 await observe('unchanged-skip',`a.fixture('References');a.action('open:blocking');a.action('revise');a.action('confirm-rewind');a.action('clay:skip');return {decision:st().clay.decision,locations:st().clay.locations.length,stale:st().clay.staleAnchors,anchors:st().anchors,gate:q('#nd-gate').innerText}`);
 await observe('review-selection',`a.fixture('Review');a.choose(0);return {selected:st().shots[st().selected[0]].id,images:[...r.querySelectorAll('.review-pair b')].map(x=>x.textContent),finding:q('.finding').innerText,inspector:q('.inspector-header').innerText}`);
 await observe('hidden-design-phase',`a.fixture('Leer','Generic');a.editField({dataset:{field:'briefText'},value:'Ein Film über Mut.'});a.action('approve');return {phase:st().current,sidebar:q('[data-open="brief"]').innerText,gate:q('#nd-gate').innerText,surface:q('#nd-surface-tools').innerText,navForCurrent:!!q('[data-open="design"]')}`);
 await observe('take-manual-checks',`a.fixture('Takes');a.action('studio:take-review');return {dialog:q('.dialog').innerText,manualControls:r.querySelectorAll('[data-sx^="review-"]').length,saveDisabled:q('[data-do="studio:take-review-save"]').disabled}`);
 await observe('shared-actor-position',`a.fixture('Blocking');const before=st().clay.cameras['1A'].location;a.action('clay:object-mouse');const e=q('[data-clay-field="object-x"]');e.value='4';e.dispatchEvent(new Event('change',{bubbles:true}));a.action('clay:shot-0');return {selected:st().shots[0].id,location:st().clay.cameras['1A'].location,sharedActorX:st().clay.locations.find(x=>x.id===before).objects.find(x=>x.id==='mouse').x,perShotActorPoses:st().clay.cameras['1A'].poses||null,ui:q('#nd-inspector').innerText}`);
 await observe('blocking-96-shots',`a.fixture('Blocking');let s=st();const orig=s.shots.slice();s.shots=Array.from({length:96},(_,i)=>({...orig[i%6],id:'S'+String(i+1).padStart(3,'0')}));s.clay.cameras=Object.fromEntries(s.shots.map((v,i)=>[v.id,{...s.clay.cameras[orig[i%6].id]}]));a.restore(s);const stage=q('.clay-stage').getBoundingClientRect(),canvas=q('#nd-canvas').getBoundingClientRect(),work=q('.clay-workspace'),bar=q('.clay-shotbar');return {shotbarHeight:bar.getBoundingClientRect().height,stageHeight:stage.height,stageClipped:stage.bottom>canvas.bottom,viewport:canvas.height,workClient:work.clientHeight,workScroll:work.scrollHeight,simulationNoteVisible:q('.clay-simulation').getBoundingClientRect().bottom<=canvas.bottom}`);
 await writeFile(out+'/adversarial-probes.json',JSON.stringify(findings,null,2));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
