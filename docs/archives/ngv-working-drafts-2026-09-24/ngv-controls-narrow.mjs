import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import vm from 'node:vm';
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






 const out=here+'/review/control-spacing-2026-09-19';await mkdir(out,{recursive:true});
 const source=await readFile(here+'/desktop-production-workbench.studio.js','utf8');
 const commands=Object.keys(vm.runInNewContext('('+source.match(/ const tasks=(\{[^\n]+\});/)[1]+')'));
 const measurements=[];
 await call('Page.bringToFront',{},session);
 async function inspect(name,scope='#ngv-desk'){
  const m=await run(`const labels=[...document.querySelectorAll(${JSON.stringify(scope)}+' label')].filter(l=>l.querySelector(':scope>input:is([type=checkbox],[type=radio])')&&l.offsetWidth&&l.offsetHeight);return {name:${JSON.stringify(name)},items:labels.map(l=>{const input=l.querySelector('input'),span=l.querySelector('span'),i=input.getBoundingClientRect(),b=l.getBoundingClientRect(),s=span?.getBoundingClientRect(),line=span?parseFloat(getComputedStyle(span).lineHeight):0;return {label:l.textContent.trim(),type:input.type,disabled:input.disabled,gap:s?s.left-i.right:null,center:s?Math.round((i.top+i.height/2-s.top-line/2)*100)/100:null,width:i.width,height:i.height,clipped:!!s&&(s.right>b.right+1||s.bottom>b.bottom+1),left:Math.round(i.left*10)/10};}),taskOverflow:q('#nd-task').scrollWidth>q('#nd-task').clientWidth};`);
  measurements.push(m);return m;
 }
 async function capture(name,selector='#nd-task'){
  await run(`q(${JSON.stringify(selector)}).scrollIntoView({block:'center'});`);await sleep(120);
  const b=await run(`const b=q(${JSON.stringify(selector)}).getBoundingClientRect();return{x:Math.max(0,b.x-8),y:Math.max(0,b.y-8),width:Math.min(innerWidth,b.width+16),height:b.height+16}`);
  const img=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false,clip:{...b,scale:1}},session);
  await writeFile(out+'/'+name+'.png',Buffer.from(img.data,'base64'));
 }


 await call('Emulation.setDeviceMetricsOverride',{width:390,height:1100,deviceScaleFactor:1,mobile:false},session);
 for(const command of ['model-research','music']){
  await run(`a.fixture('Schnitt');const s=st();s.studio.uiScale=130;a.restore(s);a.action('studio:${command}');q('#nd-task').scrollIntoView({block:'center'});`);await sleep(200);
  console.log(JSON.stringify(await run(`const t=q('#nd-task'),b=t.getBoundingClientRect(),p=document.elementFromPoint(b.x+30,b.y+30);return{task:b.toJSON(),root:r.getBoundingClientRect().toJSON(),scroll:scrollY,rootScroll:r.scrollTop,rootScrollHeight:r.scrollHeight,hit:p?.outerHTML.slice(0,150)};`)));
  const img=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);
  await writeFile(out+'/narrow-full-'+command+'.png',Buffer.from(img.data,'base64'));
 }
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
