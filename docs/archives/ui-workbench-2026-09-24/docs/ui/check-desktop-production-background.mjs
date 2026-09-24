import {spawn} from 'node:child_process';
import {readFile, writeFile, unlink} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here=path.dirname(fileURLToPath(import.meta.url));
const chrome=spawn(process.env.CHROME_BIN||'google-chrome',['--headless=new','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--no-first-run','--remote-debugging-pipe','--window-size=1048,980','about:blank'],{stdio:['ignore','ignore','ignore','pipe','pipe']});
let next=0,buffer='',session;const pending=new Map();
chrome.stdio[4].on('data',chunk=>{buffer+=chunk.toString();let idx;while((idx=buffer.indexOf('\0'))>=0){const msg=JSON.parse(buffer.slice(0,idx));buffer=buffer.slice(idx+1);if(pending.has(msg.id)){const {resolve,reject}=pending.get(msg.id);pending.delete(msg.id);msg.error?reject(Error(JSON.stringify(msg.error))):resolve(msg.result);}}});
function call(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});chrome.stdio[3].write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0');});}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const evalJS=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},session);if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
const deadline=setTimeout(()=>{chrome.kill();process.exitCode=1;console.error('Browser check timed out');},45000);
const results=[];let inlinePath;
try {
 let targetFile=path.join(here,'desktop-production-workbench.html');if(process.env.NGV_MOCK_FILE){inlinePath='/tmp/ngv-background-inline-check-'+process.pid+'.html';await writeFile(inlinePath,'<!doctype html><html><head><meta charset="utf-8"><style>body{margin:12px;background:#141518}</style></head><body>'+await readFile(process.env.NGV_MOCK_FILE,'utf8')+'</body></html>');targetFile=inlinePath;}
 await call('Browser.getVersion'); const {targetId}=await call('Target.createTarget',{url:pathToFileURL(targetFile).href+'?view=Schnitt'});session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;await sleep(600);
 await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false},session);
 const setup=`const r=document.getElementById('ngv-desk'),a=r.ngvTest,q=s=>r.querySelector(s),st=()=>a.state();`;
 const run=code=>evalJS(`(()=>{${setup}${code}})()`);
 async function test(name,code){try{const pass=await run(code);results.push({name,pass:!!pass});console.log((pass?'PASS ':'FAIL ')+name);}catch(e){results.push({name,pass:false,error:e.message.slice(0,1200)});console.log('ERROR '+name+' '+e.message.slice(0,500));}}
 const change=(selector,value)=>run(`{const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.value=${JSON.stringify(String(value))};el.dispatchEvent(new Event('change',{bubbles:true}));}`);
 async function click(selector){const p=await run(`const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.scrollIntoView({block:'nearest'});const b=el.getBoundingClientRect();return{x:b.x+b.width/2,y:b.y+b.height/2}`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p},session);await sleep(50);}
 async function shot(name){const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-studio-'+name+'.png',Buffer.from(image.data,'base64'));}


 await test('Two independent indicators in all workspaces',`return ['Medien','Storyboard','Schnitt','Postproduction','Export'].every(v=>{a.fixture(v);return [...r.querySelectorAll('.bg-indicator')].length===2&&q('[data-do="background:ai"]').dataset.state==='idle'&&q('[data-do="background:export"]').dataset.state==='idle'})`);
 await test('Opening AI changes no project state',`const before=JSON.stringify(st());q('[data-do="background:ai"]').click();return !q('#nd-background').hidden&&q('#nd-background').textContent.includes('Keine laufenden KI-Aufträge')&&JSON.stringify(st())===before&&!q('.dialog-shade')`);
 await click('[data-do="background:export"]');
 await test('Switching indicators opens only the requested flyout',`return q('[data-do="background:ai"]').getAttribute('aria-expanded')==='false'&&q('[data-do="background:export"]').getAttribute('aria-expanded')==='true'&&q('#nd-background').getAttribute('aria-label')==='Exporte'`);
 await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27},session);
 await test('Escape closes and returns focus to invoking indicator',`return q('#nd-background').hidden&&document.activeElement===q('[data-do="background:export"]')`);
 await click('[data-do="background:ai"]');
 await click('[data-do="background:ai"]');
 await test('Second click closes without a layout toggle',`return q('#nd-background').hidden&&st().sidebarVisible&&st().inspector`);
 await run(`a.action('background:ai');`);
 await click('[data-do="workspace:post"]');
 await test('Click outside dismisses and preserves requested workspace action',`return st().view==='post'&&q('#nd-background').hidden`);
 await run(`a.fixture('Export');a.action('finish:export');a.action('finish:start-export');a.action('background:export');`);
 await test('Actual export activates only export indicator',`return st().running&&q('[data-do="background:export"]').dataset.state==='running'&&q('[data-do="background:ai"]').dataset.state==='idle'&&!q('#nd-background').hidden`);
 await sleep(430);
 await test('Open export flyout updates progress from its job',`return q('#nd-background').textContent.includes('46 %')&&q('#nd-background progress').value===.46&&st().finish.job.stage===1`);
 await sleep(850);
 await test('Completed export remains inspectable without active spinner',`return !st().running&&!q('#nd-background').hidden&&q('#nd-background').textContent.includes('Abgeschlossen')&&!q('#nd-bg-buttons .busy')`);
 await run(`a.action('background:close');a.action('finish:export');a.action('finish:start-export');a.action('background:export');q('[data-do="background:stop"]').click();`);
 await test('Export cancel targets export and records cancellation',`return !st().running&&st().finish.exports.at(-1).status==='cancelled'&&q('#nd-background').textContent.includes('Abgebrochen')&&q('[data-do="background:ai"]').dataset.state==='idle'`);
 await sleep(1300);
 await test('Cancelled export never completes from a stale timer',`return st().finish.exports.at(-1).status==='cancelled'`);
 await run(`a.fixture('Medien');a.action('gen:open');const e=q('[data-generation="prompt"]');e.value='Morgenlicht';e.dispatchEvent(new Event('input',{bubbles:true}));a.action('gen:review');a.action('gen:run');a.action('background:ai');`);
 await test('Manual AI generation uses nonmodal activity and unknown progress',`return st().running&&st().modal===null&&q('[data-do="background:ai"]').dataset.state==='running'&&q('[data-do="background:export"]').dataset.state==='idle'&&!q('#nd-background progress').hasAttribute('value')`);
 await test('Dismissal and workspace switch leave AI job running',`a.action('background:close');const hidden=q('#nd-background').hidden;a.action('workspace:edit');a.action('background:ai');return hidden&&st().running&&st().view==='edit'&&!q('#nd-background').hidden`);
 await sleep(400);
 await test('AI stage updates in the open flyout without invented percent',`return !q('#nd-background').hidden&&q('#nd-background').textContent.includes('Generierung läuft')&&!q('#nd-background').textContent.includes('%')`);
 await run(`q('[data-do="background:stop"]').click();`);
 await test('AI cancel does not open a generation form or activate export',`return !st().running&&!st().modal&&!st().mediaImports.some(x=>x.generated)&&q('#nd-background').textContent.includes('Abgebrochen')`);
 await run(`a.fixture('Review');{const s=st();s.reviewFixed=true;s.shots[4].stateIn='Repariert, still';s.anchorsBound=false;s.reviewVersion=s.version;a.restore(s);}a.action('approve');a.action('video-cost');a.action('studio:task-preview');a.action('studio:task-accept');a.action('background:ai');`);
 await sleep(500);
 await test('Batch reports completed results, not fictitious model progress',`return q('#nd-background').textContent.includes('1 von 6 fertig')&&q('#nd-background progress').value===1/6`);
 await test('Batch exposes shot identities and individual states',`q('#nd-background summary').click();return q('#nd-background details').open&&q('#nd-background').textContent.includes('1A · Die leere Straße · Fertig')&&q('#nd-background').textContent.includes('1B · Das kleine Zahnrad · In Arbeit')`);
 await run(`q('[data-do="background:stop"]').click();`);
 await test('Batch stop preserves output and shows interrupted state',`return !st().running&&st().takes[0].length===1&&q('[data-do="background:ai"]').dataset.state==='paused'&&!q('#nd-bg-buttons .busy')`);
 await test('Restored batch is interrupted and never silently resubmitted',`a.restore(st());return !st().running&&q('[data-do="background:ai"]').dataset.state==='paused'`);
 await run(`a.fixture('Postproduction');a.backgroundPreview('Export fehlgeschlagen');a.action('background:export');`);
 await test('Failure has visible and accessible state without spinner',`return q('[data-do="background:export"]').getAttribute('aria-label').includes('Fehlgeschlagen')&&!!q('.bg-error')&&!q('#nd-bg-buttons .busy')&&q('#nd-background').textContent.includes('Zielordner nicht erreichbar')`);
 await run(`a.backgroundPreview('KI arbeitet');a.action('background:ai');`);
 await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]},session);
 await test('Reduced motion keeps activity visible without rotation',`return getComputedStyle(q('.bg-ring.indeterminate'),'::before').animationName==='none'`);
 for(const width of [1440,1024,768,390]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1100,deviceScaleFactor:1,mobile:false},session);await run(`a.render();`);
  await test('Flyout stays inside window at '+width,`const b=q('#nd-background').getBoundingClientRect(),d=r.getBoundingClientRect();return b.left>=d.left&&b.right<=d.right&&b.top>=d.top&&b.bottom<q('#nd-status').getBoundingClientRect().top`);
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1440,height:1100,deviceScaleFactor:1,mobile:false},session);
 for(const [name,preview,kind] of [['ai','KI arbeitet','ai'],['export','Export rendert','export'],['error','Export fehlgeschlagen','export']]){
  await run(`a.fixture('Postproduction');a.backgroundPreview('${preview}');a.action('background:${kind}');`);
  const bounds=await run(`const b=r.getBoundingClientRect();return{x:b.x,y:b.y,width:b.width,height:b.height,scale:1}`);
  const img=await call('Page.captureScreenshot',{format:'png',clip:bounds,captureBeyondViewport:true},session);await writeFile(path.join(here,'review/studio-screenshots/background-'+(process.env.NGV_MOCK_FILE?'inline-':'')+name+'.png'),Buffer.from(img.data,'base64'));
 }
 await writeFile(path.join(here,'review/background-'+(process.env.NGV_MOCK_FILE?'inline-':'')+'checks.json'),JSON.stringify({results},null,2));console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,failed:results.filter(x=>!x.pass)}));if(results.some(x=>!x.pass))process.exitCode=1;
} finally {if(inlinePath)await unlink(inlinePath).catch(()=>{});clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
