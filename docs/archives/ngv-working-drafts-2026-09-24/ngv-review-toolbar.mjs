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




 await run(`a.fixture('Postproduction');a.action('workspace:media');`);
 await test('Media commands have distinct icons and accessible names', `return ['media-import','gen:open','studio:organize','studio:index'].every(id=>{const b=q('[data-do="'+id+'"]');return b&&b.querySelector('svg')&&b.getAttribute('aria-label')&&b.dataset.tooltip&&!b.textContent.trim()&&getComputedStyle(b.querySelector('svg')).width==='16px'});`);
 await test('Folder removal belongs only to folder tools', `return r.querySelectorAll('[data-do="studio:folder-delete"]').length===1&&!!q('.library-nav-foot [data-do="studio:folder-delete"]')&&!q('#nd-inspector [data-do="studio:folder-delete"]')&&q('[data-do="studio:folder-delete"]').disabled;`);
 await click('[data-do="media-import"]');
 await test('Import icon opens existing import sheet', `return st().modal==='media-import'&&!st().running;`);
 await run(`a.action('close');`);
 await click('[data-do="gen:open"]');
 await test('Generation icon opens provider and prompt configuration without starting', `return !!q('[data-generation="prompt"]')&&!st().running;`);
 await run(`a.action('close');`);
 await click('[data-do="studio:organize"]');
 await test('Organization opens a proposal before making changes', `return st().studio.task?.kind==='organize'&&st().studio.task.stage==='prepare'&&!st().running;`);
 await run(`a.action('studio:task-close');`);
 await click('[data-do="studio:index"]');
 await test('Search index control opens the index settings', `return st().modal==='studio-settings'&&st().studio.settings==='storage';`);
 await run(`a.action('close');`);
 await click('[data-do="pool:new"]');
 await test('New-folder icon opens name entry', `return st().modal==='pool-new';`);
 await run(`a.action('close');a.action('pool:folder-sound');`);
 await test('Selected folder enables its own rename and remove controls', `return !q('[data-do="pool:rename"]').disabled&&!q('[data-do="studio:folder-delete"]').disabled;`);
 await click('[data-do="studio:folder-delete"]');
 await test('Folder removal asks confirmation and names its target', `return q('.dialog-shade')?.textContent.includes('Ton')&&q('.dialog-shade')?.textContent.includes('Medien bleiben unter Importe erhalten')&&!st().running;`);
 await run(`a.action('close');`);
 await test('KI icon is inside ring and label outside', `const b=q('[data-do="background:ai"]');return !!b.querySelector('.bg-ring svg[data-lucide="sparkles"]')&&!b.querySelector('.bg-ring').textContent.trim()&&b.querySelector('.bg-ring+span').textContent==='KI';`);
 await click('[data-do="background:ai"]');
 await test('KI indicator still opens the correct flyout', `return !q('#nd-background').hidden&&q('#nd-background').textContent.includes('Keine laufenden KI-Aufträge');`);
 await run(`a.action('background:close');a.action('pool:folder-all');`);
 for(const width of [1048,768,390]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1050,deviceScaleFactor:1,mobile:false},session);
  await run(`a.render();`);
  await test('Folder tools remain visible at '+width, `const b=q('.library-nav-foot');return getComputedStyle(b).display!=='none'&&b.getBoundingClientRect().height>0;`);
  await test('Media command row stays in its pane at '+width, `const pane=q('#nd-surface-tools').getBoundingClientRect();return [...r.querySelectorAll('.media-actions button')].every(b=>{const x=b.getBoundingClientRect();return x.left>=pane.left&&x.right<=pane.right;});`);
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1050,deviceScaleFactor:1,mobile:false},session);
 await run(`a.fixture('Postproduction');a.action('workspace:media');`);
 const bounds=await run(`const b=r.getBoundingClientRect();return{x:b.x,y:b.y,width:b.width,height:b.height,scale:1}`);
 const img=await call('Page.captureScreenshot',{format:'png',clip:bounds,captureBeyondViewport:true},session);await writeFile(path.join(here,'review/studio-screenshots/media-toolbar-symbols.png'),Buffer.from(img.data,'base64'));
 await writeFile(path.join(here,'review/toolbar-symbol-checks.json'),JSON.stringify({results},null,2));
 if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
