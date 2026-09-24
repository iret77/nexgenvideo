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





 const cases=[['media',"a.fixture('Medien')"],['intake',"a.fixture('Leer','Music Video')"],['audio',"a.fixture('Audio')"],['brief-empty',"a.fixture('Leer','Generic')"],['brief',"a.fixture('Storyboard');a.action('open:brief')"],['treatment',"a.fixture('Storyboard');a.action('open:treatment')"],['script',"a.fixture('Storyboard');a.action('open:script')"],['storyboard',"a.fixture('Storyboard')"],['animatic',"a.fixture('Storyboard');a.action('mode:animatic')"],['planning',"a.fixture('Shotplanung')"],['references',"a.fixture('References')"],['review',"a.fixture('Review')"],['takes',"a.fixture('Takes')"],['edit',"a.fixture('Schnitt')"],['post',"a.fixture('Postproduction')"],['export',"a.fixture('Export')"],['preview',"a.fixture('Export');a.action('finish-section:preview')"],['album',"a.fixture('Export');a.action('finish-section:album')"]];
 const layouts=[];const output=process.env.NGV_POLISH_STAGE||'before';
 for(const [name,init] of cases){
  await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false},session);await run(init);await call('Page.bringToFront',{},session);await sleep(120);
  const bounds=await run(`const b=r.getBoundingClientRect();return{x:b.x,y:b.y,width:b.width,height:b.height,scale:1}`);
  if(name==='storyboard')console.log('Capture-selection',await run(`return {scroll:q('#nd-canvas').scrollTop,tile:q('.shot-tile[aria-pressed=true]').getBoundingClientRect().toJSON()}`));
  const img=await call('Page.captureScreenshot',{format:'png',clip:bounds,captureBeyondViewport:false},session);await writeFile(path.join(here,'review/polish-2026-09-19/'+output+'-'+name+'.png'),Buffer.from(img.data,'base64'));
  for(const width of [1440,1048,768]){await call('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false},session);await run('a.render();');layouts.push(await run(`const rect=s=>{const x=q(s)?.getBoundingClientRect();return x?{x:x.x,y:x.y,w:x.width,h:x.height,bottom:x.bottom}:null};return {name:${JSON.stringify(name)},width:${width},title:rect('#nd-title'),toolbar:rect('#nd-surface-tools'),inspector:rect('.inspector-header'),sidebar:rect('#nd-browser'),sidebarHead:rect('#nd-browser .sidebar-tabs,#nd-browser .library-nav-head,#nd-browser .pane-heading'),overflow:r.scrollWidth-r.clientWidth,canvasOverflow:q('#nd-canvas').scrollWidth-q('#nd-canvas').clientWidth,buttons:[...r.querySelectorAll('button')].filter(b=>getComputedStyle(b).display!=='none'&&b.clientWidth&&b.scrollWidth>b.clientWidth+2).map(b=>b.getAttribute('aria-label')||b.textContent.trim()).slice(0,12)};`));}
 }
 await writeFile(path.join(here,'review/polish-2026-09-19/'+output+'-geometry.json'),JSON.stringify(layouts,null,2));console.log('Captured '+cases.length+' workspaces and '+layouts.length+' layout states');
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
