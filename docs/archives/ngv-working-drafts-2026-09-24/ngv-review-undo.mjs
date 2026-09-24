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



 await test('No titlebar Undo/Redo in any workspace', `return ['media','production','edit','post','finish'].every(view=>{a.action('workspace:'+view);return !q('#nd-title [data-do="undo"]')&&!q('#nd-title [data-do="redo"]')&&!q('.undo-icon')});`);
 await run(`a.fixture('Postproduction');a.nleSelect(st().nle.clips[0].id);const e=q('[data-grade="exposure"]');e.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));e.value='1';e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));q('.project-title').focus();`);
 await test('Exposure edit is applied', `return st().nle.clips[0].exposure===1;`);
 await call('Input.dispatchKeyEvent',{type:'keyDown',key:'z',code:'KeyZ',modifiers:4,windowsVirtualKeyCode:90},session);
 await call('Input.dispatchKeyEvent',{type:'keyUp',key:'z',code:'KeyZ',modifiers:4,windowsVirtualKeyCode:90},session);
 await test('Command-Z undoes content while retaining workspace', `return st().nle.clips[0].exposure===0&&st().view==='post';`);
 await run(`q('.project-title').focus();`);
 await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Z',code:'KeyZ',modifiers:12,windowsVirtualKeyCode:90},session);
 await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Z',code:'KeyZ',modifiers:12,windowsVirtualKeyCode:90},session);
 await test('Shift-Command-Z restores content while retaining workspace', `return st().nle.clips[0].exposure===1&&st().view==='post';`);
 await run(`a.action('workspace:media');`);
 await test('Typing keeps input undo separate', `const e=q('input[type="search"]')||q('input');if(!e)return false;const before=JSON.stringify(st());const key=new KeyboardEvent('keydown',{key:'z',metaKey:true,bubbles:true,cancelable:true});e.dispatchEvent(key);return !key.defaultPrevented&&JSON.stringify(st())===before;`);
 for(const view of ['media','post']){
  await run(`a.action('workspace:'+${JSON.stringify(view)});`);
  await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1050,deviceScaleFactor:1,mobile:false},session);
  const bounds=await run(`const b=r.getBoundingClientRect();return{x:b.x,y:b.y,width:b.width,height:b.height,scale:1}`);
  const img=await call('Page.captureScreenshot',{format:'png',clip:bounds,captureBeyondViewport:true},session);await writeFile(path.join(here,'review/studio-screenshots/undo-titlebar-'+view+'.png'),Buffer.from(img.data,'base64'));
 }
 if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
