import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir, rm} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here='<local NexGenVideo checkout>/docs/ui';
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











 const out=path.join(here,'review','media-spacing-2026-09-20');await mkdir(out,{recursive:true});
 const geometry=[];
 for(const [width,scale]of [[1440,100],[1048,100],[900,100],[1048,130],[768,100]]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false},session);
  await run(`a.fixture('Schnitt');a.action('workspace:media');a.action('pool:folder-sketches');a.action('studio:settings');const input=q('[data-sx="uiScale"]');input.value=${scale};input.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:modal-close');a.render();`);
  await sleep(80);
  geometry.push(await run(`const bounds=el=>{const b=el.getBoundingClientRect();return {x:b.x,y:b.y,right:b.right,bottom:b.bottom,width:b.width,height:b.height};};const f=q('.library-filters'),c=q('[data-media-ai]'),l=c.nextElementSibling,search=q('.search-scope'),input=q('[data-media-search]');return {width:${width},scale:${scale},font:getComputedStyle(l).fontSize,pane:bounds(f),checkboxGap:bounds(l).x-bounds(c).right,searchGap:bounds(input).x-bounds(search).right,checkboxCenter:Math.abs((bounds(c).y+bounds(c).height/2)-(bounds(l).y+bounds(l).height/2)),groups:[...f.children].map(bounds),overflow:f.scrollWidth>f.clientWidth};`));
  const pic=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(path.join(out,'media-'+width+'-'+scale+'.png'),Buffer.from(pic.data,'base64'));
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 await run(`a.fixture('Schnitt');`);await sleep(60);const pic=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(path.join(out,'picker.png'),Buffer.from(pic.data,'base64'));
 await writeFile(path.join(out,'geometry.json'),JSON.stringify(geometry,null,2));console.log(JSON.stringify(geometry));console.log('Runtime errors',runtimeErrors.length);
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}
