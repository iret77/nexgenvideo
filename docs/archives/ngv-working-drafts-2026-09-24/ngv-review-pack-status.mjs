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





 await run(`a.fixture('Postproduction');`);
 const observations=[];
 for(const width of [1440,1048,768,390]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1050,deviceScaleFactor:1,mobile:false},session);
  await run(`a.render();`);
  const before=await run(`const p=q('.pack-status'),s=getComputedStyle(p),b=p.getBoundingClientRect(),t=q('#nd-title').getBoundingClientRect();return {width:${width},label:p.textContent,tag:p.tagName,tabIndex:p.tabIndex,action:p.dataset.do||null,background:s.backgroundColor,border:s.borderWidth,cursor:s.cursor,inside:b.left>=t.left&&b.right<=t.right,clipped:q('.pack-name').scrollWidth>q('.pack-name').clientWidth+1,box:{x:b.x+b.width/2,y:b.y+b.height/2}};`);
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',...before.box},session);
  const hover=await run(`return {background:getComputedStyle(q('.pack-status')).backgroundColor,cursor:getComputedStyle(q('.pack-status')).cursor};`);
  await click('.pack-status');
  observations.push({...before,hover,modal:await run(`return st().modal;`)});
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1050,deviceScaleFactor:1,mobile:false},session);
 await run(`a.fixture('Postproduction');`);
 const bounds=await run(`const b=r.getBoundingClientRect();return{x:b.x,y:b.y,width:b.width,height:b.height,scale:1}`);
 const img=await call('Page.captureScreenshot',{format:'png',clip:bounds,captureBeyondViewport:true},session);await writeFile(path.join(here,'review/studio-screenshots/format-pack-status.png'),Buffer.from(img.data,'base64'));
 await run(`a.fixture('Leer','Generic');`);
 observations.push(await run(`return {generic:q('.pack-status').textContent,accessible:q('.pack-status').getAttribute('aria-label')};`));
 console.log(JSON.stringify(observations,null,2));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
