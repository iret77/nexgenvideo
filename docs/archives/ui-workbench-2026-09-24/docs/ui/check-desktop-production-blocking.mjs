import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here=path.dirname(fileURLToPath(import.meta.url));
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







 const out=here+'/review/optional-blocking-2026-09-19';await mkdir(out,{recursive:true});
 await call('Page.bringToFront',{},session);
 async function capture(name){await sleep(120);const img=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(out+'/'+name+'.png',Buffer.from(img.data,'base64'));}
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 await test('Greenfield does not invent a scene',`a.fixture('Leer','Generic');a.action('open:blocking');return st().current==='brief'&&!st().clay.locations.length&&!q('canvas[data-clay]')&&!q('[data-do="clay:start"]')`);
 await test('Shot planning has one successor and no duplicate Blocking tab',`a.fixture('Shotplanung');return !q('[data-do="mode:blocking"]')&&!!q('[data-open="blocking"]')`);
 await test('Approval enters optional decision before References',`a.action('approve');return st().current==='blocking'&&!a.readiness()&&!!q('[data-do="clay:skip"]')&&!!q('[data-do="clay:start"]')`);
 await capture('optional-decision');
 await test('Skip is a valid, free, artifact-free path',`const cost=st().cost;a.action('clay:skip');return st().current==='refs'&&st().done.blocking&&st().clay.decision==='skipped'&&st().cost===cost&&!st().clay.locations.length`);
 await test('An existing project is not rewound by migration',`a.fixture('Takes');let s=st();delete s.clay;delete s.done.blocking;delete s.have.blocking;a.restore(s);return st().current==='takes'&&st().clay.decision==='skipped'&&a.readiness()`);
 await test('Blocking fixture exposes actual editable scene and shared cameras',`a.fixture('Blocking');return st().current==='blocking'&&st().clay.locations.length===1&&new Set(Object.values(st().clay.cameras).map(c=>c.location)).size===1&&!!q('canvas[data-clay="space"]')`);
 await capture('space');
 await test('Scene viewport draws geometry',`const el=q('canvas[data-clay="space"]'),data=el.getContext('2d').getImageData(0,0,el.width,el.height).data;let colors=new Set();for(let i=0;i<data.length;i+=40)colors.add(data.slice(i,i+3).join());return colors.size>10`);
 await test('Free orbit does not modify shot cameras or geometry',`const cameras=JSON.stringify(st().clay.cameras),scene=JSON.stringify(st().clay.locations);const s=st();s.clay.orbit+=.2;a.restore(s);return JSON.stringify(st().clay.cameras)===cameras&&JSON.stringify(st().clay.locations)===scene`);
 await test('Camera travel uses shot duration, with its own transport',`a.action('clay:view-camera');return !!q('.clay-transport')&&q('[data-clay-field="time"]').max==='5'&&!q('.animatic-transport')&&!q('[data-field="duration"]')`);
 await capture('camera');
 await run(`a.action('clay:play');`);await sleep(250);
 await test('Camera travel really advances',`return st().clay.time>0`);
 await test('Switching to space stops playback and removes transport',`a.action('clay:view-space');return !q('.clay-transport')`);
 await test('Object position changes update shared location truth',`const revision=st().clay.revision;const e=q('[data-clay-field="object-x"]');e.value='1.3';e.dispatchEvent(new Event('change',{bubbles:true}));return st().clay.locations[0].objects[0].x===1.3&&st().clay.revision===revision+1&&!a.readiness()`);
 await test('Scene changes support undo',`a.action('undo');return st().clay.locations[0].objects[0].x===0`);
 await test('Location duplicate affects selected shot only',`a.action('clay:duplicate-location');return st().clay.locations.length===2&&st().clay.cameras['1E'].location==='location-2'&&st().clay.cameras['1A'].location==='street'`);
 await test('A second shot can reuse the same new location',`a.action('clay:shot-3');const e=q('[data-clay-field="location"]');e.value='location-2';e.dispatchEvent(new Event('change',{bubbles:true}));return st().clay.cameras['1D'].location==='location-2'&&st().clay.cameras['1E'].location==='location-2'`);
 await test('Clay snapshots are explicit outputs, not fabricated AI anchors',`a.action('clay:view-outputs');a.action('clay:derive');return Object.keys(st().clay.outputs).length===6&&!st().anchors&&!a.readiness()&&st().clay.outputs['1D'].location.id==='location-2'`);
 await capture('outputs');
 await test('Unsighted geometry cannot be approved',`a.action('approve');return st().current==='blocking'`);
 await test('Every snapshot must be sighted',`for(let i=0;i<6;i++){a.action('clay:output-'+i);a.action('clay:accept');}return a.readiness()`);
 await test('Geometry changes invalidate outputs without relabelling old evidence',`a.action('clay:view-space');const prev=st().clay.outputs['1F'].revision;const e=q('[data-clay-field="object-x"]');e.value='2';e.dispatchEvent(new Event('change',{bubbles:true}));a.action('clay:view-outputs');return !a.readiness()&&st().clay.outputs['1F'].revision===prev&&q('.clay-results').textContent.includes('Veraltet')`);
 await test('Fresh derived and accepted outputs allow References',`a.action('clay:derive');for(let i=0;i<6;i++){a.action('clay:output-'+i);a.action('clay:accept');}a.action('approve');return st().current==='refs'&&st().done.blocking&&st().clay.approved===st().clay.revision`);
 await test('References carry a separate positioning source',`return q('#nd-inspector').textContent.includes('2D-Positionierung')&&!st().anchors`);
 await capture('reference-binding');
 await test('Approved scene is read-only',`a.action('open:blocking');a.action('clay:view-space');return q('[data-clay-field="object-x"]').disabled`);
 await test('Changing duration invalidates snapshot evidence',`const s=st();s.shots[0].duration++;s.current=s.view='review';s.have.review=true;s.reviewRun=s.reviewFixed=true;s.reviewVersion=s.version;a.restore(s);return !a.readiness()`);
 await test('Import with shot plan enters optional decision',`a.fixture('Leer','Generic');a.action('import');a.action('adopt-import');return st().current==='blocking'&&st().imported.plan&&!st().clay.locations.length`);
 await test('Video jobs reject stale Clay bindings',`a.fixture('Blocking');let s=st();s.current=s.view='takes';s.have.takes=true;a.restore(s);a.action('prepare-video');return !st().running&&!st().studio.task`);
 await test('Leaving an active scene requires explicit skip confirmation',`a.fixture('Blocking');a.action('clay:skip');return st().current==='blocking'&&st().modal==='clay-skip'&&!!q('[data-do="clay:confirm-skip"]')`);
 await test('Cancelling skip preserves the location',`a.action('close');return st().current==='blocking'&&st().clay.decision==='used'&&st().clay.locations.length===1`);
 await test('Confirmed skip retains the draft but removes its production role',`a.action('clay:skip');a.action('clay:confirm-skip');return st().current==='refs'&&st().clay.decision==='skipped'&&st().clay.locations.length===1&&!q('canvas[data-clay]')`);
 await test('Skipped scene reactivation requires explicit rewind',`a.action('open:blocking');a.action('revise');return st().done.blocking&&st().modal==='rewind'&&st().current==='refs'`);
 await test('Reactivation restores editing with the same scene',`a.action('confirm-rewind');return st().current==='blocking'&&st().clay.decision==='used'&&!st().done.blocking&&st().clay.locations.length===1`);
 await test('Generic workflow offers the same Blocking capability',`a.fixture('Shotplanung');const s=st();s.pack='Generic';a.restore(s);a.action('approve');a.action('clay:start');return st().current==='blocking'&&st().clay.locations.length===1&&st().pack==='Generic'`);
 await test('Lens belongs to Shot Planning and requires explicit rewind',`a.fixture('Blocking');a.action('clay:view-camera');const f=st().clay.cameras['1E'].fov;a.action('clay:revise-plan');return st().modal==='rewind'&&st().view==='plan'&&st().current==='blocking'&&f<30&&f>25`);
 await test('Missing pack blocks scene edits',`a.fixture('Blocking');const s=st();s.studio.packAvailable=false;a.restore(s);const revision=st().clay.revision;a.action('clay:derive');return !a.readiness()&&st().clay.revision===revision&&!Object.keys(st().clay.outputs).length`);
 await run(`a.fixture('Blocking');const s=st();s.studio.uiScale=130;a.restore(s);a.action('clay:view-camera');`);await capture('camera-130');
 await test('Scene controls fit at 130 percent',`return ['#nd-canvas','#nd-surface-tools','#nd-inspector','#nd-gate'].every(sel=>{const el=q(sel);return el.scrollWidth<=el.clientWidth+1})`);
 await writeFile(out+'/checks.json',JSON.stringify(results,null,2));console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,failed:results.filter(x=>!x.pass)}));if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
