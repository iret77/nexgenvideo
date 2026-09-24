import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir, rm} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here='<local NexGenVideo checkout>/docs/ui';
const chrome=spawn(process.env.CHROME_BIN||'google-chrome',['--headless=new','--user-data-dir='+path.join(here,'review','.browser-'+process.pid),'--no-sandbox','--disable-gpu','--disable-background-networking','--no-first-run','--remote-debugging-pipe','--window-size=1048,980','about:blank'],{stdio:['ignore','ignore','inherit','pipe','pipe']});
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











 const out=path.join(here,'review','inspector-scroll-2026-09-20');await mkdir(out,{recursive:true});
 const surfaces=[];
 async function capture(name){await sleep(90);const pic=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(path.join(out,name+'.png'),Buffer.from(pic.data,'base64'));}
 async function scaleUI(scale){await run(`a.action('studio:settings');const el=q('[data-sx="uiScale"]');el.value=${scale};el.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:modal-close');`);}
 for(const fixture of ['Leer','Audio','Storyboard','Shotplanung','Blocking','References','Review','Takes','Schnitt','Postproduction','Export','Medien']){
  await run(`a.fixture(${JSON.stringify(fixture)});`);
  const result=await run(`const p=q('#nd-inspector'),body=p.querySelector('.inspector-scroll'),groups=[...p.querySelectorAll('.inspector-group')];return {fixture:${JSON.stringify(fixture)},scrollAreas:p.querySelectorAll('.inspector-scroll').length,outside:groups.filter(g=>g.parentElement!==body).map(g=>g.querySelector('summary')?.textContent),nested:p.querySelectorAll('.inspector-scroll .inspector-scroll').length,groups:groups.map(g=>g.querySelector('summary')?.textContent)};`);
  surfaces.push(result);console.log(JSON.stringify(result));
  if(['Audio','Shotplanung','Blocking'].includes(fixture)){await run(`const body=q('.inspector-scroll');body.scrollTop=body.scrollHeight;`);await capture(fixture.toLowerCase());}
 }
 for(const scale of [100,130]){
  await run(`a.fixture('Schnitt');a.action('open:board');a.choose(2);`);await scaleUI(scale);
  await run(`q('.inspector-scroll').scrollTop=10000;`);await capture('board-approved-'+scale);
  await test('Complete image-source and shot-order groups visible at '+scale,`const p=q('#nd-inspector'),body=q('.inspector-scroll'),bounds=body.getBoundingClientRect(),groups=[...body.children],source=groups.find(g=>g.querySelector('summary')?.textContent==='Bildquelle'),order=groups.find(g=>g.querySelector('summary')?.textContent==='Shotfolge'),sourceBounds=source.getBoundingClientRect(),orderBounds=order.getBoundingClientRect();return sourceBounds.top>=bounds.top&&sourceBounds.bottom<=orderBounds.top&&orderBounds.bottom<=bounds.bottom+1&&q('[data-field="name"]').disabled;`);
 }
 await test('Collapsing image source moves shot order in the same flow',`const body=q('.inspector-scroll'),source=[...body.children].find(g=>g.querySelector('summary')?.textContent==='Bildquelle'),order=[...body.children].find(g=>g.querySelector('summary')?.textContent==='Shotfolge'),before=order.offsetTop;source.querySelector('summary').click();return !source.open&&order.offsetTop<before;`);
 await run(`a.fixture('Storyboard');a.choose(2);q('.inspector-scroll').scrollTop=10000;`);await capture('board-editable');
 await test('Shot-order edit remains connected',`const before=st().shots.map(x=>x.id);q('[data-do="wf:previous"]').click();const after=st().shots.map(x=>x.id);return after[1]===before[2]&&after[2]===before[1]&&q('#nd-inspector').querySelectorAll('.inspector-scroll').length===1;`);
 await test('Repeated Inspector rendering creates no nested or orphan groups',`a.choose(1);a.render();a.render();a.action('mode:moments');const p=q('#nd-inspector'),body=p.querySelector('.inspector-scroll');return p.querySelectorAll('.inspector-scroll').length===1&&[...p.querySelectorAll('.inspector-group')].every(g=>g.parentElement===body);`);
 await run(`a.fixture('Storyboard');a.choose(2);const state=st();state.shots[2].moments[0].asset=null;a.restore(state);q('.inspector-scroll').scrollTop=10000;`);await capture('sketch-missing');
 await test('Late sketch controls share the same scroll area',`const group=[...r.querySelectorAll('#nd-inspector .inspector-group')].find(g=>g.querySelector('summary')?.textContent==='Sketch');return group?.parentElement===q('.inspector-scroll')&&!!group.querySelector('[data-do="wf:sketch"]');`);
 await writeFile(path.join(out,'checks.json'),JSON.stringify({surfaces,results,runtimeErrors},null,2));console.log('Runtime errors',runtimeErrors.length);
 if(runtimeErrors.length||results.some(x=>!x.pass)||surfaces.some(s=>s.scrollAreas!==1||s.outside.length||s.nested))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}
