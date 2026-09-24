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










 const out=here+'/review/final-ux-2026-09-19';
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 const findings=[];
 async function observe(name,code){const result=await run(code);findings.push({name,...result});console.log(JSON.stringify({name,...result}));await sleep(120);const img=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/probe-'+name+'.png',Buffer.from(img.data,'base64'));}
 await observe('rewind-take-retention',`a.fixture('Takes');const before={takes:Object.values(st().takes).flat().length,chosen:Object.keys(st().chosen).length};a.action('open:plan');a.action('revise');a.action('confirm-rewind');const after={takes:Object.values(st().takes).flat().length,chosen:Object.keys(st().chosen).length,history:Object.values(st().previousTakes.shots).flat().length};a.action('open:takes');a.action('mode:history');const historyButtons=[...r.querySelectorAll('[data-take]')].map(e=>({label:e.getAttribute('aria-label'),disabled:e.disabled}));a.action('open:media');const mediaTakeButtons=[...r.querySelectorAll('[data-do^="asset:take-"]')].length;return {before,after,historyButtons,mediaTakeButtons,canvas:q('#nd-canvas').innerText.slice(0,2000)}`);
 await observe('evidence-user-attestation',`a.fixture('Review');const before={reviewRun:st().reviewRun,reviewFixed:st().reviewFixed,reviewVersion:st().reviewVersion};a.action('studio:checks');const prepare=q('#nd-task').innerText;const options=[...r.querySelectorAll('[data-task-option]')].map(e=>({checked:e.checked,disabled:e.disabled}));a.action('studio:task-preview');a.action('studio:task-accept');return {before,after:{reviewRun:st().reviewRun,reviewFixed:st().reviewFixed,reviewVersion:st().reviewVersion},prepare,options,result:q('#nd-task').innerText}`);
 await observe('storyboard-editability',`a.fixture('Storyboard');return {buttons:[...r.querySelectorAll('button')].filter(e=>e.getBoundingClientRect().width).map(e=>({label:e.textContent.trim()||e.getAttribute('aria-label'),action:e.dataset.do})),draggables:[...r.querySelectorAll('[draggable=true]')].map(e=>e.outerHTML.slice(0,200))}`);
 await observe('animatic-song-timing',`a.fixture('Storyboard');a.action('mode:animatic');return {track:st().track,shotDuration:st().shots.reduce((n,s)=>n+s.duration,0),dock:q('.sequence-dock').innerText,audioElements:r.querySelectorAll('audio').length,canvas:q('#nd-canvas').innerText.slice(0,1400)}`);
 await observe('reference-clay-compare',`a.fixture('Blocking');a.action('clay:derive');for(let i=0;i<6;i++){a.action('clay:output-'+i);a.action('clay:accept');}a.action('approve');let s=st();s.identities=true;s.identityCount=4;s.anchors=true;s.anchorCount=6;s.have.refs=true;s.refMode='anchors';a.restore(s);a.action('ref-compare');return {toolbar:q('#nd-surface-tools').innerText,canvas:q('#nd-canvas').innerText,clayThumbs:r.querySelectorAll('.clay-binding').length}`);
 await writeFile(out+'/fable-verification-probes.json',JSON.stringify(findings,null,2));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
