import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
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

try {
 await call('Browser.getVersion');
 const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Schnitt'});
 session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;await sleep(700);await call('Page.bringToFront',{},session);
 const run=code=>evalJS(`(()=>{const r=document.getElementById('ngv-desk'),a=r.ngvTest,q=s=>r.querySelector(s);${code}})()`);
 const out=here+'/review/chrome-spacing-2026-09-19';await mkdir(out,{recursive:true});
 const tag=process.argv[2]||'after',reports=[];
 for(const [width,scale,pack] of [[960,100,'Generic'],[1048,100,'Music Video'],[1048,130,'Generic'],[768,100,'Generic'],[390,100,'Generic']]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1100,deviceScaleFactor:1,mobile:false},session);
  await run(`a.fixture('Leer',${JSON.stringify(pack)});a.action('workspace:edit');const s=a.state();s.studio.uiScale=${scale};a.restore(s);`);await sleep(120);
  reports.push({width,scale,pack,...await run(`const selectors=['.project-title>span:first-child','.workspace-switch button','.pack-caption','.pack-name','.panel-toggle svg'];const items=selectors.flatMap(sel=>[...r.querySelectorAll(sel)].filter(e=>e.getBoundingClientRect().width).map(e=>{const b=e.getBoundingClientRect(),c=getComputedStyle(e),range=document.createRange();range.selectNodeContents(e);const t=range.getBoundingClientRect();return{label:e.textContent||'icon',top:b.top,height:b.height,center:b.top+b.height/2,textCenter:t.top+t.height/2,font:c.fontSize,line:c.lineHeight}}));const buttons=[...q('.nle-empty').querySelectorAll('button')].map(e=>e.getBoundingClientRect());return{items,buttonGap:buttons[1].top-buttons[0].bottom,overflow:r.scrollWidth>r.clientWidth,titleHeight:q('#nd-title').getBoundingClientRect().height}`)});
  const img=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/'+tag+'-'+width+'-'+scale+'.png',Buffer.from(img.data,'base64'));
 }
 console.log(JSON.stringify(reports));await writeFile(out+'/'+tag+'.json',JSON.stringify(reports,null,2));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
