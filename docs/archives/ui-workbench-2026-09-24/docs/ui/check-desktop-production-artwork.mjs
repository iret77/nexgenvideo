import {spawn} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
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





 await run(`a.fixture('Export');a.action('finish-section:preview');`);
 await test('Vorschaubild reachable without album artwork', `return !!q('[data-preview-time]')&&q('#nd-inspector').textContent.includes('Vorschaubild');`);
 await test('Optional by default', `return !st().finish.preview.enabled&&st().finish.preview.bound===null;`);
 await test('Slider stays mounted during frame scrubbing', `const slider=q('[data-preview-time]');slider.value=4;slider.dispatchEvent(new Event('input',{bubbles:true}));return slider.isConnected&&st().finish.preview.time===4;`);
 await click('[data-do="artwork:apply-preview"]');
 await test('Frame selection is captured explicitly', `return st().finish.preview.enabled&&st().finish.preview.bound.time===4;`);
 await run(`a.action('finish-section:delivery');a.action('finish:export');`);
 await test('Export save sheet includes image sidecar', `return st().modal==='finish-export'&&q('.dialog').textContent.includes('PNG');`);
 await click('[data-do="finish:start-export"]');await sleep(1400);
 await test('Export keeps its own image snapshot', `const x=st().finish.exports[0];return x.status==='complete'&&x.preview.time===4&&x.preview.name.endsWith('-preview.png')&&q('#nd-inspector').textContent.includes(x.preview.name);`);
 await run(`a.action('finish-section:preview');`);
 await change('[data-preview-time]',7);
 await test('Changing image requires renewed selection', `return !q('[data-do="artwork:apply-preview"]').disabled&&st().finish.exports[0].preview.time===4;`);
 await run(`a.action('finish-section:delivery');a.action('finish:export');`);
 await test('Unapplied changes block only opted-in video preview', `return st().modal!== 'finish-export';`);
 await run(`a.action('finish-section:preview');a.action('artwork:apply-preview');a.action('finish-section:delivery');a.action('finish:export');a.action('finish:start-export');`);await sleep(1400);
 await test('Subsequent export cannot overwrite prior image', `const xs=st().finish.exports;return xs.length===2&&xs[0].preview.time===4&&xs[1].preview.time===7;`);
 await run(`a.action('finish-section:preview');a.action('artwork:mode-media');`);
 const imageId=await run(`return [...q('[data-artwork="asset"]').options].find(o=>o.value)?.value;`);
 await change('[data-artwork="asset"]',imageId);
 await click('[data-do="artwork:apply-preview"]');
 await test('Existing media can be assigned as export preview', `return st().finish.preview.bound.mode==='media'&&st().finish.preview.bound.asset.id===${JSON.stringify(imageId)};`);
 await run(`a.action('finish-section:album');`);
 await test('Album artist and title are not inferred', `return st().cover.artist===''&&st().cover.title==='';`);
 await test('No sketch offered as rendered album reference', `return !q('[data-artwork="reference"]').textContent.includes('Sketch');`);
 await change('[data-artwork="reference"]',imageId);
 await click('[data-do="artwork:generate"]');
 await test('Album generation opens cost confirmation before running', `return st().modal==='gen-cost'&&!st().running;`);
 await click('[data-do="gen:back"]');
 await test('Amending album quote returns to contextual inspector', `return st().modal===null&&!!q('[data-artwork="subject"]');`);
 await run(`window.pipelineBefore=JSON.stringify([st().done,st().version,st().current]);window.costBefore=st().cost;a.action('artwork:generate');`);
 await click('[data-do="gen:run"]');
 await test('Artwork generation appears as KI activity', `return st().running&&!!q('[data-do="background:ai"] .busy')&&!q('[data-do="background:export"] .busy');`);await sleep(1400);
 await test('Generated album is separate project media', `return st().mediaImports.some(x=>x.generation?.cover?.kind==='album')&&st().cost>window.costBefore;`);
 await click('[data-do="artwork:keep"]');
 await test('Clean album variant retained for typography', `return !!st().cover.clean['1:1']&&st().cover.kept.length===1;`);
 await change('[data-artwork="variant"]','text');
 await test('Typography requires explicit artist and title', `return q('[data-do="artwork:generate"]').disabled;`);
 await change('[data-artwork="artist"]','The Test Artist');await change('[data-artwork="title"]','Test Album');
 await run(`a.action('artwork:generate');a.action('gen:run');`);await sleep(1400);
 await click('[data-do="artwork:keep"]');
 await test('Typography preserves clean image and phase approvals', `return st().cover.kept.length===2&&st().cover.clean['1:1']!==st().cover.selected['1:1']&&JSON.stringify([st().done,st().version,st().current])===window.pipelineBefore;`);
 await click('[data-do="artwork:aspect-9:16"]');await click('[data-do="artwork:skip"]');
 await test('Skipped format is visible and cannot run accidentally', `return q('.artwork-caption').textContent.includes('übersprungen')&&q('[data-do="artwork:generate"]').disabled;`);
 await click('[data-do="artwork:skip"]');await change('[data-artwork="variant"]','clean');
 await run(`window.cancelCost=st().cost;window.cancelCount=st().mediaImports.length;a.action('artwork:generate');a.action('gen:run');a.action('gen:cancel');`);await sleep(1400);
 await test('Cancelled image job creates no asset or cost', `return !st().running&&st().cost===window.cancelCost&&st().mediaImports.length===window.cancelCount;`);
 await run(`a.fixture('Takes');a.action('workspace:finish');a.action('finish-section:album');`);
 await test('Album retains native post-pipeline gate', `return q('[data-do="artwork:generate"]').disabled&&q('#nd-inspector').textContent.includes('freigeben');`);
 await run(`a.fixture('Leer','Generic');a.action('workspace:finish');a.action('finish-section:preview');`);
 await test('Generic project has preview but no album entry', `return !!q('[data-do="finish-section:preview"]')&&!q('[data-do="finish-section:album"]')&&!!q('[data-preview-time]');`);
 await run(`a.action('artwork:mode-ai');`);await click('[data-artwork="intent"]');await call('Input.insertText',{text:'Wide city at dawn'},session);await click('[data-do="artwork:generate"]');
 await test('Typing and clicking costs works without a lost blur click', `return st().modal==='gen-cost';`);
 await run(`a.action('gen:run');`);await sleep(1400);
 await test('Generic preview generation does not need a music workflow', `return st().mediaImports.some(x=>x.generation?.cover?.kind==='preview')&&!!st().finish.preview.asset;`);
 await click('[data-do="artwork:apply-preview"]');
 await test('Generated preview is assigned only through explicit apply', `return st().finish.preview.enabled&&st().finish.preview.bound.mode==='ai';`);
 await test('Generated media keeps no transient cost-approval context', `return st().mediaImports.filter(x=>x.generation?.cover).every(x=>!('context' in x.generation.cover));`);
 await test('Saved export image selection survives reopening', `const saved=st(),id=saved.finish.preview.bound.asset.id;a.restore(saved);return st().finish.preview.bound.asset.id===id&&!st().running;`);
 await run(`a.fixture('Export');a.action('finish-section:preview');a.action('artwork:apply-preview');`);await change('[data-preview-time]',9);await run(`a.action('finish-section:delivery');`);
 await change('[data-finish-option="format"]','xml');
 await test('XML handoff is independent of unapplied video preview', `a.action('finish:export');return st().modal==='finish-export';`);
 await run(`a.action('close');a.fixture('Export');a.action('finish-section:preview');`);
 for(const width of [1440,1048,768,390]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1050,deviceScaleFactor:1,mobile:false},session);
  for(const ratio of ['16:9','1:1','9:16']){
   await change('[data-artwork="aspect"]',ratio);
   await test('Preview ratio and pane fit '+width+' '+ratio, `const b=q('.preview-frame').getBoundingClientRect(),p=q('.artwork-stage').getBoundingClientRect();return Math.abs(b.width/b.height-${ratio.replace(':','/')})<0.02&&b.left>=p.left&&b.right<=p.right;`);
  }
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1050,deviceScaleFactor:1,mobile:false},session);
 await change('[data-artwork="aspect"]','16:9');
 const screenshot=async name=>{const bounds=await run(`const b=r.getBoundingClientRect();return{x:b.x,y:b.y,width:b.width,height:b.height,scale:1}`);const img=await call('Page.captureScreenshot',{format:'png',clip:bounds,captureBeyondViewport:true},session);await writeFile(path.join(here,'review/studio-screenshots/'+name+'.png'),Buffer.from(img.data,'base64'));};
 await screenshot('export-preview');
 await run(`a.action('finish-section:album');`);await change('[data-artwork="reference"]',imageId);await run(`a.action('artwork:generate');a.action('gen:run');`);await sleep(1400);await screenshot('export-album');
 await writeFile(path.join(here,'review/artwork-checks.json'),JSON.stringify({results},null,2));
 if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
