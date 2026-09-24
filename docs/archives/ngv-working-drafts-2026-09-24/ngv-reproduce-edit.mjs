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
const deadline=setTimeout(()=>{chrome.kill();process.exitCode=1;console.error('Browser check timed out');},45000);
try{
 await call('Browser.getVersion');const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Medien'});session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;await sleep(600);
 const result=await evalJS(`(()=>{const a=document.querySelector('#ngv-desk').ngvTest,r=[];for(const f of ['Medien','Takes','Storyboard','Leer']){try{a.fixture(f);a.action('workspace:production');a.action('sidebar:media');a.action('workspace:edit');r.push({f,view:a.state().view,current:a.state().current,have:a.state().have.edit,nle:!!a.state().nle,text:document.querySelector('#nd-canvas').textContent.slice(0,160),dock:!document.querySelector('#nd-edit-dock').hidden});}catch(e){r.push({f,error:String(e)});}}a.fixture('Takes');a.action('approve');r.push({f:'approved takes',state:a.state().have,text:document.querySelector('#nd-canvas').textContent.slice(0,160),dock:!document.querySelector('#nd-edit-dock').hidden});return r;})()`);console.log(JSON.stringify(result));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
