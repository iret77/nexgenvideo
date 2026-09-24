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
 const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Schnitt'});
 session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;
 await sleep(700);await call('Emulation.setDeviceMetricsOverride',{width:1024,height:1100,deviceScaleFactor:1,mobile:false},session);await sleep(100);
 const results=[];
 async function click(selector){const p=await evalJS(`(()=>{const el=document.querySelector(${JSON.stringify(selector)});el.scrollIntoView({block:'nearest'});const r=el.getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p},session);await sleep(70);}
 await click('[data-do="pool:folder-documents"]');console.log(await evalJS(`({folder:document.querySelector('#ngv-desk').ngvTest.state().mediaFolder,filter:document.querySelector('#ngv-desk').ngvTest.state().mediaFilter,assets:Array.from(document.querySelectorAll('.media-tile')).map(a=>a.textContent)})`));await click('[data-do="asset:document-treatment"]');
 results.push(await evalJS(`({name:'physical document preview',pass:!!document.querySelector('.media-document-body')&&!document.querySelector('.nle-transport')})`));
 for(const width of [1024,736,500,320]){await call('Emulation.setDeviceMetricsOverride',{width,height:1700,deviceScaleFactor:1,mobile:false},session);await sleep(80);const shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-media-text-'+width+'.png',Buffer.from(shot.data,'base64'));results.push(await evalJS(`(()=>{const r=document.querySelector('#ngv-desk');return {name:'document layout ${width}',pass:r.scrollWidth<=r.clientWidth+1&&r.querySelector('main').clientWidth>140,pool:r.querySelector('.pool-results').getBoundingClientRect().height}})()`));}
 await call('Emulation.setDeviceMetricsOverride',{width:1024,height:1100,deviceScaleFactor:1,mobile:false},session);
 await click('[data-do="pool:folder-all"]');await click('[data-media-search]');await call('Input.insertText',{text:'Skript'},session);await sleep(80);
 results.push(await evalJS(`({name:'physical search focus',pass:document.activeElement.matches('[data-media-search]')&&document.querySelectorAll('.media-tile').length===1})`));
 await click('[data-do="asset:document-script"]');await call('Input.dispatchKeyEvent',{type:'keyDown',key:'ArrowDown',code:'ArrowDown'},session);await call('Input.dispatchKeyEvent',{type:'keyUp',key:'ArrowDown',code:'ArrowDown'},session);
 results.push(await evalJS(`({name:'library keyboard never seeks timeline',pass:document.querySelector('#ngv-desk').ngvTest.state().nle.cursor===0})`));
 await click('[data-do="pool:clear"]').catch(()=>{});
 await evalJS(`(()=>{const a=document.querySelector('#ngv-desk').ngvTest;a.fixture('Schnitt');a.action('pool:folder-footage');a.action('pool:toggle-footage');a.action('pool:folder-footage-scene');a.action('pool:view-grid')})()`);await sleep(100);
 const shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-media-video-grid.png',Buffer.from(shot.data,'base64'));
 results.push(await evalJS(`({name:'video thumbnail browser has useful height',pass:document.querySelector('.pool-results').clientHeight>=200&&document.querySelectorAll('.media-tile').length===12})`));
 await writeFile(path.join(here,'review/media-browser-checks.json'),JSON.stringify(results,null,2)+'\n');console.log(JSON.stringify(results));if(results.some(r=>!r.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
