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
 await call('Browser.getVersion');
 const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Storyboard'});
 session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;
 await sleep(600);
 const observations=[];
 for(const mode of ['board','animatic','moments','board']){
  observations.push(await evalJS(`(()=>{const r=document.getElementById('ngv-desk'),a=r.ngvTest;a.action('mode:${mode}');return {mode:a.state().mode,footer:r.querySelector('#nd-bottom').textContent,playButton:!!r.querySelector('[data-do=play]'),scrubber:!!r.querySelector('[data-scrub]'),canvasHeight:r.querySelector('#nd-canvas').clientHeight};})()`));
  if(mode==='animatic'){
   await evalJS("document.querySelector('[data-do=play]').click()");await sleep(130);
   observations.push(await evalJS("(()=>{const r=document.getElementById('ngv-desk'),a=r.ngvTest;const playing=a.state().playing;a.action('mode:board');r.dispatchEvent(new KeyboardEvent('keydown',{key:' ',bubbles:true}));return {playingBefore:playing,playingAfterLeaving:a.state().playing,modeAfterSpace:a.state().mode};})()"));
  }
 }
 console.log(JSON.stringify(observations));
 const shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);
 await writeFile('/tmp/ngv-storyboard-without-transport.png',Buffer.from(shot.data,'base64'));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
