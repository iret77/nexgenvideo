import {spawn} from 'node:child_process';
import {writeFile,mkdir} from 'node:fs/promises';
import {createInterface} from 'node:readline';
const chrome=spawn('google-chrome',['--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--no-first-run','--remote-debugging-pipe','--window-size=1280,1000','about:blank'],{stdio:['ignore','ignore','ignore','pipe','pipe']});
let next=0,buffer='',session;const pending=new Map();
chrome.stdio[4].on('data',c=>{buffer+=c.toString();let i;while((i=buffer.indexOf('\0'))>=0){const m=JSON.parse(buffer.slice(0,i));buffer=buffer.slice(i+1);if(pending.has(m.id)){const {resolve,reject}=pending.get(m.id);pending.delete(m.id);m.error?reject(Error(JSON.stringify(m.error))):resolve(m.result);}}});
function call(method,params={},sid=session){return new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});chrome.stdio[3].write(JSON.stringify({id,method,params,...(sid?{sessionId:sid}:{})})+'\0');});}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function js(expression){const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;}
const {targetId}=await call('Target.createTarget',{url:'file://<local NexGenVideo checkout>/docs/ui/desktop-production-workbench.html'});
session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;
await call('Emulation.setDeviceMetricsOverride',{width:1280,height:1000,deviceScaleFactor:1,mobile:false});await sleep(500);
console.log('READY');
await mkdir('/tmp/ngv-first-use',{recursive:true});
const log=[];
for await(const line of createInterface({input:process.stdin})){
 try {const c=JSON.parse(line);let result;
 if(c.type==='read') result=await js(`(()=>{const r=document.getElementById('ngv-desk');return {text:r.innerText,controls:[...r.querySelectorAll('button,input,textarea,select,[role="button"]')].filter(e=>e.getClientRects().length).map((e,i)=>({i,tag:e.tagName,text:e.innerText?.trim(),title:e.title,aria:e.getAttribute('aria-label'),disabled:e.disabled,value:e.value,type:e.type,act:e.dataset.do,field:e.dataset.field,id:e.id,placeholder:e.placeholder,...(e.tagName==='SELECT'?{options:[...e.options].map(o=>({value:o.value,text:o.text}))}:{})}))}})()`);
 else if(c.type==='click'){const p=await js(`(()=>{const a=[...document.getElementById('ngv-desk').querySelectorAll('button,input,textarea,select,[role="button"]')].filter(e=>e.getClientRects().length);const e=${c.selector?'document.querySelector('+JSON.stringify(c.selector)+')':'a['+c.i+']'};if(!e)throw Error('Missing control');if(e.disabled)throw Error('Disabled control');e.scrollIntoView({block:'nearest'});const b=e.getBoundingClientRect();return {x:b.x+b.width/2,y:b.y+b.height/2}})()`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p});await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p});await sleep(80);result='clicked';}
 else if(c.type==='fill') result=await js(`(()=>{const a=[...document.getElementById('ngv-desk').querySelectorAll('button,input,textarea,select,[role="button"]')].filter(e=>e.getClientRects().length);const e=a[${c.i}];if(e.disabled||e.readOnly)throw Error('Field not editable');e.focus();e.value=${JSON.stringify(c.value)};e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return 'filled';})()`);
 else if(c.type==='screenshot'){const s=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});await writeFile('/tmp/ngv-first-use/'+c.name+'.png',Buffer.from(s.data,'base64'));result='/tmp/ngv-first-use/'+c.name+'.png';}
 else if(c.type==='eval') result=await js(c.code);
 else if(c.type==='wait'){await sleep(Math.min(c.ms,5000));result='waited';}
 else if(c.type==='close'){await call('Browser.close');break;}
 log.push({command:c,result});await writeFile('/tmp/ngv-first-use/trace.json',JSON.stringify(log,null,2));console.log(JSON.stringify(result));
 }catch(e){console.log(JSON.stringify({error:e.message}));}
}
chrome.kill();
