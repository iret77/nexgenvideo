import {spawn} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here='<local NexGenVideo checkout>/docs/ui';
const chrome=spawn(process.env.CHROME_BIN||'google-chrome',['--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--no-first-run','--remote-debugging-pipe','--window-size=1048,980','about:blank'],{stdio:['ignore','ignore','ignore','pipe','pipe']});
let next=0,buffer='',session;const pending=new Map();
chrome.stdio[4].on('data',chunk=>{buffer+=chunk.toString();let idx;while((idx=buffer.indexOf('\0'))>=0){const msg=JSON.parse(buffer.slice(0,idx));buffer=buffer.slice(idx+1);if(pending.has(msg.id)){const {resolve,reject}=pending.get(msg.id);pending.delete(msg.id);msg.error?reject(Error(JSON.stringify(msg.error))):resolve(msg.result);}}});
function call(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});chrome.stdio[3].write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0');});}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const evalJS=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},session);if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
const deadline=setTimeout(()=>{chrome.kill();process.exitCode=1;console.error('Browser check timed out');},80000);
try{
 await call('Browser.getVersion');
 const {targetId}=await call('Target.createTarget',{url:'file:///tmp/ngv-icon-review.html'});
 session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;
 const topSession=session;
 await sleep(25000);
 await call('Page.stopLoading',{},session);
 await sleep(300);
 const tree=await call('Page.getFrameTree',{},session);
 const targets=await call('Target.getTargets');
 const child=targets.targetInfos.find(t=>t.type==='iframe');
 
 if(child)session=(await call('Target.attachToTarget',{targetId:child.targetId,flatten:true})).sessionId;
 const childTree=await call('Page.getFrameTree',{},session);
 const frameId=tree.frameTree.childFrames?.[0]?.frame.id||childTree.frameTree.frame.id;
 const {executionContextId}=await call('Page.createIsolatedWorld',{frameId,worldName:'ngv-review'},session);
 const inspect=async expression=>(await call('Runtime.evaluate',{expression,contextId:executionContextId,returnByValue:true,awaitPromise:true},session)).result.value;
 console.log(await evalJS('JSON.stringify({scripts:Array.from(document.scripts).map(s=>({id:s.id,src:s.src,size:s.textContent.length})),lucide:typeof globalThis.lucide,resources:performance.getEntriesByType("resource").map(r=>({name:r.name.slice(0,160),duration:r.duration,size:r.transferSize}))})'));
 console.log(await inspect('JSON.stringify({buttons:document.querySelectorAll(".panel-toggle").length,icons:document.querySelectorAll(".panel-toggle svg").length,main:document.querySelector("main")?.clientWidth})'));
 let icons=await inspect('Array.from(document.querySelectorAll("svg[data-lucide]")).map(s=>({name:s.getAttribute("data-lucide"),svg:s.outerHTML}))');
 await evalJS("(()=>{const a=document.getElementById('ngv-desk').ngvTest;a.action('pool:sort');a.action('nle:mute');a.action('nle:hide');a.action('nle:play')})()");
 icons.push(...await inspect('Array.from(document.querySelectorAll("svg[data-lucide]")).map(s=>({name:s.getAttribute("data-lucide"),svg:s.outerHTML}))'));
 await evalJS("document.getElementById('ngv-desk').ngvTest.fixture('Schnitt')");
 await writeFile('/tmp/ngv-supplied-panel-icons.json',JSON.stringify(icons));
 const shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},topSession);await writeFile('/tmp/ngv-icons-review.png',Buffer.from(shot.data,'base64'));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
