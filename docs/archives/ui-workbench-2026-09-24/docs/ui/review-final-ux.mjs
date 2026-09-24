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
 await call('Page.bringToFront',{},session);
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 const inventory=[];
 async function capture(name){await sleep(150);const img=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/'+name+'.png',Buffer.from(img.data,'base64'));inventory.push({name,...await run(`return {state:{workspace:st().view,current:st().current,fixture:st().fixture},text:q('#nd-canvas').innerText,inspector:q('#nd-inspector').innerText,gate:q('#nd-gate').innerText,controls:[...r.querySelectorAll('button')].filter(b=>b.getBoundingClientRect().width).map(b=>({text:b.innerText,aria:b.getAttribute('aria-label'),action:b.dataset.do,disabled:b.disabled})),overflow:r.scrollWidth>r.clientWidth}`)});}
 for(const [name,code] of [
 ['export',`a.fixture('Export');`],['media',`a.fixture('Medien');`],['audio',`a.fixture('Audio');`],
 ['brief-empty',`a.fixture('Leer','Generic');`],['brief-populated',`a.fixture('Storyboard');a.action('open:brief');`],
 ['treatment',`a.action('open:treatment');`],['script',`a.action('open:script');`],
 ['storyboard',`a.fixture('Storyboard');`],['animatic',`a.action('mode:animatic');`],
 ['plan',`a.fixture('Shotplanung');`],['blocking-space',`a.fixture('Blocking');`],['blocking-camera',`a.action('clay:view-camera');`],
 ['references',`a.fixture('References');`],['review',`a.fixture('Review');`],['takes',`a.fixture('Takes');`],
 ['edit',`a.fixture('Schnitt');`],['post',`a.fixture('Postproduction');`],['generator',`a.fixture('Medien');a.action('gen:open');`]
 ]){await run(code);await capture(name);}
 await writeFile(out+'/surface-inventory.json',JSON.stringify(inventory,null,2));console.log(JSON.stringify(inventory.map(x=>({name:x.name,overflow:x.overflow}))));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
