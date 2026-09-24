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






 const out=here+'/review/settings-layout-2026-09-19';
 const tabs=['general','agent','providers','models','packs','storage'];
 const measurements=[];
 await call('Page.bringToFront',{},session);
 for(const width of [1048,390]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:980,deviceScaleFactor:1,mobile:false},session);
  await run(`a.fixture('Leer','Generic');a.action('studio:settings');`);
  for(const tab of tabs){
   await run(`a.action('studio:settings-${tab}');`);await sleep(120);
   const m=await run(`const d=q('.dialog'),form=q('.settings-form'),footer=q('.dialog-actions'),b=d.getBoundingClientRect(),f=form.getBoundingClientRect(),close=q('[data-do="studio:modal-close"]').getBoundingClientRect();return {tab:${JSON.stringify(tab)},width:${width},dialog:{x:b.x,y:b.y,width:b.width,height:b.height},overflow:d.scrollWidth>d.clientWidth,bodyOverflow:q('.studio-dialog-body').scrollWidth>q('.studio-dialog-body').clientWidth,footerGap:footer.getBoundingClientRect().top-f.bottom,rightInset:b.right-close.right,checkboxGaps:[...d.querySelectorAll('.finish-check')].map(l=>l.querySelector('span').getBoundingClientRect().left-l.querySelector('input').getBoundingClientRect().right),controlAxes:[...form.querySelectorAll('.property>input,.property>select,.property>strong,.settings-controls')].map(el=>Math.round(el.getBoundingClientRect().left*10)/10)};`);
   measurements.push(m);
   const b=m.dialog;
   const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false,clip:{x:Math.max(0,b.x-16),y:Math.max(0,b.y-16),width:Math.min(width,b.width+32),height:b.height+32,scale:1}},session);
   await writeFile(out+'/'+width+'-'+tab+'.png',Buffer.from(image.data,'base64'));
  }
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:980,deviceScaleFactor:1,mobile:false},session);
 await run(`a.fixture('Leer','Generic');a.action('studio:settings');a.action('studio:settings-general');`);
 await click('[data-sx="notify"]');
 results.push({name:'Checkbox label toggles state',pass:!await run('return st().studio.notify')});
 await change('[data-sx="uiScale"]',130);
 results.push({name:'UI scale stored',pass:await run('return st().studio.uiScale===130')});
 for(const tab of tabs){
  await run(`a.action('studio:settings-${tab}');`);await sleep(120);
  const m=await run(`const d=q('.dialog');return {tab:${JSON.stringify(tab)},scale:130,overflow:d.scrollWidth>d.clientWidth||q('.studio-dialog-body').scrollWidth>q('.studio-dialog-body').clientWidth,tabRows:[...d.querySelectorAll('.studio-settings-tabs button')].map(b=>b.getBoundingClientRect().top)};`);measurements.push(m);
 }
 await click('[data-do="studio:modal-close"]');
 results.push({name:'Close dismisses dialog',pass:await run('return !st().modal&&!q(".dialog")')});
 for(const kind of ['project-settings','mcp-add']){
  await run(`a.action('studio:${kind}');`);await sleep(120);
  const b=await run(`const b=q('.dialog').getBoundingClientRect();return{x:b.x,y:b.y,width:b.width,height:b.height}`);
  const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false,clip:{x:b.x-16,y:b.y-16,width:b.width+32,height:b.height+32,scale:1}},session);
  await writeFile(out+'/130-'+kind+'.png',Buffer.from(image.data,'base64'));
 }
 await writeFile(out+'/measurements.json',JSON.stringify({measurements,interactions:results},null,2));
 console.log(JSON.stringify({measurements,interactions:results}));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
