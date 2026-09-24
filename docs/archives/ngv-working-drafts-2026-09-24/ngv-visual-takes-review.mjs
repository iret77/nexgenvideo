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






 const out=here+'/review/visual-takes-2026-09-19';await mkdir(out,{recursive:true});
 await call('Page.bringToFront',{},session);
 async function capture(name){await sleep(120);const img=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/'+name+'.png',Buffer.from(img.data,'base64'));}
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1100,deviceScaleFactor:1,mobile:false},session);
 await test('Empty project preserves truth and offers one actual current-phase action',`a.fixture('Leer','Generic');a.action('open:takes');return st().shots.length===0&&st().current==='brief'&&!q('#nd-canvas .thumb-image')&&r.querySelectorAll('[data-do="open:brief"]').length===1&&!q('#nd-inspector').textContent.includes('Arbeitsstand')`);
 await capture('empty-takes');
 await test('Model research stays inside settings',`a.action('studio:settings');a.action('studio:settings-models');a.action('studio:model-research');return st().modal==='studio-model-research'&&q('#nd-task').hidden&&!!q('.dialog [data-task-option]')`);
 await capture('model-settings');
 await test('Research is not accepted before explicit review',`return !st().studio.modelEvidence&&!q('[data-do="studio:task-accept"]')`);
 await run(`a.action('studio:task-preview');a.action('studio:task-accept');`);
 await test('Acceptance returns to models and does not alter pipeline',`return st().studio.modelEvidence&&st().modal==='studio-settings'&&st().current==='brief'&&!Object.keys(st().done).length&&q('#nd-task').hidden`);
 await test('Legacy research task is hidden after restoring a project',`const s=st();s.studio.task.stage='prepare';a.restore(s);return st().view==='takes'&&q('#nd-task').hidden&&!q('.dialog')`);
 await test('Future takes show existing sketches without pretending they are anchors',`a.fixture('Storyboard');a.action('open:takes');return q('.take-board').textContent.includes('Storyboard · Sketch')&&!q('#nd-canvas .reference')&&[...r.querySelectorAll('[data-take]')].length===0&&!q('[data-do="prepare-video"]')`);
 await capture('planned-shots');
 await run(`a.fixture('References');a.action('open:takes');`);await capture('anchors-without-takes');
 await test('Every shot offers source and its own takes',`a.fixture('Takes');return r.querySelectorAll('.take-board-row').length===st().shots.length&&r.querySelectorAll('[data-take]').length===12&&!q('.sequence-lane')`);
 await capture('take-board');
 await click('[data-take="2"][data-take-shot="2"]');
 await test('Take review opens the clicked shot without selecting it as final',`return st().selected[0]===2&&st().studio.takeFocus===2&&st().modal==='studio-take-review'&&st().chosen[2]===1`);
 await run(`a.fixture('Review');{const s=st();s.reviewFixed=true;s.reviewVersion=s.version;a.restore(s);}a.action('approve');a.action('prepare-video');`);
 await test('Batch selection is attached to visual shots',`return st().have.takes&&st().studio.task.kind==='batch'&&r.querySelectorAll('.take-board [data-task-option]').length===6&&!q('#nd-task [data-task-option]')`);
 await test('Batch preparation has only one action area',`return q('#nd-gate').hidden&&!q('#nd-task').hidden`);
 await test('Starting before cost review is rejected',`a.action('studio:task-accept');return !st().running&&st().studio.task.stage==='prepare'`);
 await capture('batch-selection');
 await click('[data-task-option="2"]');
 await run(`a.action('studio:task-preview');`);
 await test('Costs follow selected shots and reviewed selection is locked',`return st().studio.task.cost===2&&st().studio.task.selected.length===5&&[...r.querySelectorAll('[data-task-option]')].every(e=>e.disabled)`);
 await capture('batch-cost');
 await test('Stale batch surfaces a recovery action',`const s=st();s.version++;a.restore(s);return q('[data-do="studio:task-accept"]').disabled&&!!q('[data-do="studio:task-recheck"]')`);
 await run(`a.action('studio:task-recheck');a.action('studio:task-preview');`);
 await run(`a.action('studio:task-accept');`);await sleep(520);
 await test('Completed take appears while other shots are still running',`return st().running&&st().takes[0]?.length===1&&!!q('[data-take-shot="0"]')`);
 await run(`a.action('studio:batch-stop');`);
 await test('Stopped batch keeps finished results',`return !st().running&&st().studio.task.stage==='paused'&&st().takes[0].length===1`);
 await run(`a.action('studio:batch-resume');`);for(let i=0;i<60&&await run('return st().running');i++)await sleep(100);
 await test('Completion preserves omitted shot and hides completed interaction',`return !st().running&&st().studio.task.stage==='done'&&!st().takes[2]?.length&&q('#nd-task').hidden&&!q('#nd-gate').hidden`);
 await test('Cancelling preparation restores current-phase action',`a.action('prepare-video');a.action('studio:task-close');return !st().studio.task&&!q('#nd-gate').hidden&&!!q('[data-do="prepare-video"]')`);
 await run(`a.fixture('Takes');const s=st();s.studio.uiScale=130;a.restore(s);`);await capture('take-board-130');
 await test('Take board fits central canvas at enlarged scale',`const box=q('#nd-canvas');return box.scrollWidth<=box.clientWidth&&[...r.querySelectorAll('.take-shot-heading')].every(x=>x.scrollWidth<=x.clientWidth)`);
 await writeFile(out+'/checks.json',JSON.stringify(results,null,2));console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,failed:results.filter(x=>!x.pass)}));if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
