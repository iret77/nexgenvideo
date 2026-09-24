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
 for(const width of [1048,768,390])for(const scale of [100,130]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1100,deviceScaleFactor:1,mobile:false},session);
  for(const command of commands){
   await run(`a.fixture('Schnitt');const s=st();s.studio.uiScale=${scale};a.restore(s);a.action('studio:${command}');`);
   await inspect(width+'-'+scale+'-'+command,'#nd-task');
   if(width===1048&&scale===100&&['model-research','music','captions','organize','tutorial'].includes(command)||width===390&&scale===130&&['model-research','music'].includes(command))await capture(width+'-'+scale+'-'+command);
  }
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1100,deviceScaleFactor:1,mobile:false},session);
 await run(`a.fixture('Leer','Generic');a.action('studio:settings');a.action('studio:settings-models');a.action('studio:model-research');`);
 await capture('model-research-from-settings');
 await click('[data-task-option="1"]+span');
 await test('Checkbox caption toggles only its option and retains focus',`return JSON.stringify(st().studio.task.selected)==='[0,2]'&&document.activeElement.dataset.taskOption==='1'`);
 await call('Input.dispatchKeyEvent',{type:'keyDown',key:' ',code:'Space',windowsVirtualKeyCode:32},session);
 await call('Input.dispatchKeyEvent',{type:'keyUp',key:' ',code:'Space',windowsVirtualKeyCode:32},session);
 await test('Space toggles the focused checkbox',`return st().studio.task.selected.length===3&&document.activeElement.dataset.taskOption==='1'`);
 await run(`a.action('studio:task-preview');`);await inspect('model-review','#nd-task');await capture('model-review');
 await test('Reviewed choices are disabled',`return [...r.querySelectorAll('[data-task-option]')].every(e=>e.disabled)`);
 await run(`a.action('studio:task-accept');`);await capture('model-done');
 await test('Model evidence result remains connected',`return st().studio.modelEvidence&&st().studio.task.stage==='done'`);
 await run(`a.fixture('Schnitt');a.action('studio:music');`);
 await click('[data-task-option="1"]+span');
 await test('Radio choice stays exclusive and retains focus',`return JSON.stringify(st().studio.task.selected)==='[1]'&&document.activeElement.dataset.taskOption==='1'`);
 await change('[data-task-input]','Leise Streicher');
 await run(`a.action('studio:task-preview');`);
 await test('Optional input reaches the proposal',`return st().studio.task.detail.includes('Leise Streicher')`);
 await run(`a.fixture('Review');a.action('approve');a.action('video-cost');`);await inspect('video-batch','#nd-task');await capture('video-batch');
 const contexts=[
  ['settings-general',"a.fixture('Leer','Generic');a.action('studio:settings');a.action('studio:settings-general');",'.dialog'],
  ['settings-models',"a.fixture('Medien');a.action('studio:settings');a.action('studio:settings-models');",'.dialog'],
  ['mcp',"a.fixture('Leer','Generic');a.action('studio:mcp-add');",'.dialog'],
  ['take-review',"a.fixture('Takes');a.action('studio:take-review');",'.dialog'],
  ['take-rescue',"a.fixture('Takes');a.action('studio:take-rescue');",'.dialog'],
  ['inspector',"a.fixture('Schnitt');a.action('nle:tab-video');",'#nd-inspector'],
  ['post-review',"a.fixture('Postproduction');a.action('studio:post-review');",'#nd-inspector'],
  ['export',"a.fixture('Export');",'#nd-inspector'],
  ['preview',"a.fixture('Export');a.action('finish-section:preview');",'#nd-inspector'],
  ['media',"a.fixture('Medien');",'.library-filters'],
  ['generation-music',"a.fixture('Medien');a.action('gen:open');a.action('gen:type-audio');const e=q('[data-generation=provider]');e.value='ElevenLabs';e.dispatchEvent(new Event('change',{bubbles:true}));const m=q('[data-generation=model]');m.value='elevenlabs-music';m.dispatchEvent(new Event('change',{bubbles:true}));",'.dialog']
 ];
 for(const [name,code,selector] of contexts){await run(code);await run(`for(const d of r.querySelectorAll('.inspector-group'))d.open=true;`);await inspect(name);await capture(name,selector);}
 await test('Every native check control in reviewed surfaces uses the shared layout',`return [...r.querySelectorAll('input[type=checkbox],input[type=radio]')].every(x=>x.closest('label.finish-check'))`);
 const failures=measurements.flatMap(m=>m.items.filter(i=>i.gap!==8||Math.abs(i.center)>1||i.width!==16||i.height!==16||i.clipped).map(i=>({context:m.name,...i}))).concat(measurements.filter(m=>m.taskOverflow).map(m=>({context:m.name,overflow:true})));
 await writeFile(out+'/measurements.json',JSON.stringify({taskCommands:commands,measurements,interactions:results,failures},null,2));
 console.log(JSON.stringify({taskCommands:commands.length,contexts:measurements.length,controls:measurements.reduce((n,m)=>n+m.items.length,0),interactions:results,failures}));
 if(failures.length||results.some(r=>!r.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
