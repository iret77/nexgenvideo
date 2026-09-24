import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const chrome=spawn(process.env.CHROME_BIN||'google-chrome',['--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--no-first-run','--remote-debugging-pipe','--window-size=1048,980','about:blank'],{stdio:['ignore','ignore','ignore','pipe','pipe']});
let next=0,buffer='',session;const pending=new Map();
chrome.stdio[4].on('data',chunk=>{buffer+=chunk.toString();let idx;while((idx=buffer.indexOf('\0'))>=0){const msg=JSON.parse(buffer.slice(0,idx));buffer=buffer.slice(idx+1);if(msg.method==='Runtime.exceptionThrown')runtimeErrors.push(msg.params.exceptionDetails);if(pending.has(msg.id)){const {resolve,reject}=pending.get(msg.id);pending.delete(msg.id);msg.error?reject(Error(JSON.stringify(msg.error))):resolve(msg.result);}}});
function call(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});chrome.stdio[3].write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0');});}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const evalJS=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},session);if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
const deadline=setTimeout(()=>{chrome.kill();process.exitCode=1;console.error('Browser check timed out');},90000);
const results=[],runtimeErrors=[];
try {
 await call('Browser.getVersion'); const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Schnitt'});session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;await sleep(600);
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 const setup=`const r=document.getElementById('ngv-desk'),a=r.ngvTest,q=s=>r.querySelector(s),st=()=>a.state();`;
 const run=code=>evalJS(`(()=>{${setup}${code}})()`);
 async function test(name,code){try{const pass=await run(code);results.push({name,pass:!!pass});console.log((pass?'PASS ':'FAIL ')+name);}catch(e){results.push({name,pass:false,error:e.message.slice(0,1200)});console.log('ERROR '+name+' '+e.message.slice(0,500));}}
 const change=(selector,value)=>run(`{const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.value=${JSON.stringify(String(value))};el.dispatchEvent(new Event('change',{bubbles:true}));}`);
 async function click(selector){const p=await run(`const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.scrollIntoView({block:'nearest'});const b=el.getBoundingClientRect();return{x:b.x+b.width/2,y:b.y+b.height/2}`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p},session);await sleep(50);}
 async function shot(name){const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-studio-'+name+'.png',Buffer.from(image.data,'base64'));}










 const out=path.join(here,'review/acceptance-2026-09-20');
 const cases=[['media',"a.fixture('Medien');"],['edit',"a.fixture('Schnitt');"],['post',"a.fixture('Postproduction');"],['references',"a.fixture('References');a.action('wf:refs-layout');"],['settings',"a.fixture('Storyboard');a.action('studio:settings');"],['greenfield',"a.fixture('Leer','Generic');"],['camera',"a.fixture('Blocking');a.action('clay:view-camera');a.action('clay:sketch');"],['generate',"a.fixture('Medien');a.action('gen:open');"]];
 for(const [name,code] of cases){await run(code);await sleep(120);const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/'+name+'.png',Buffer.from(image.data,'base64'));}
 await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1050,deviceScaleFactor:1,mobile:false},session);await run("a.fixture('Schnitt');");await sleep(120);const wide=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/edit-wide.png',Buffer.from(wide.data,'base64'));
 const fragment=await readFile('<local home>/.codex/visualizations/2026/09/12/01a0956c-ab36-7ed3-b838-cf38a6f4b3b7/nexgenvideo-desktop-workbench.html','utf8');
 const inline='/tmp/ngv-inline-acceptance.html';await writeFile(inline,'<!doctype html><html><meta charset="utf-8"><body style="margin:0">'+fragment+'</body></html>');
 await call('Page.navigate',{url:pathToFileURL(inline).href},session);await sleep(900);await call('Emulation.setDeviceMetricsOverride',{width:1024,height:950,deviceScaleFactor:1,mobile:false},session);
 await test('Inline-Fragment lädt und nutzt die volle Arbeitshöhe',`return !!a&&q('.clay-stage').getBoundingClientRect().height>300&&r.getBoundingClientRect().height>=800;`);
 await test('Inline wechselt Arbeitsräume ohne leere Hauptfläche',`a.fixture('Schnitt');a.action('workspace:media');const media=q('#nd-canvas').innerText.includes('Medien');a.action('workspace:edit');return media&&!!q('.studio-viewer')&&q('.nle-scroll').getBoundingClientRect().height>100;`);
 await writeFile(out+'/inline-checks.json',JSON.stringify(results,null,2));console.log(JSON.stringify(results));if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
