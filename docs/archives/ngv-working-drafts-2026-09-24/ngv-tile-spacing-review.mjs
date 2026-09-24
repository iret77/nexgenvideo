import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir, rm} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here='<local NexGenVideo checkout>/docs/ui';
const chrome=spawn(process.env.CHROME_BIN||'google-chrome',['--headless=new','--user-data-dir='+path.join(here,'review','.browser-'+process.pid),'--no-sandbox','--disable-gpu','--disable-background-networking','--no-first-run','--remote-debugging-pipe','--window-size=1048,980','about:blank'],{stdio:['ignore','ignore','inherit','pipe','pipe']});
let next=0,buffer='',session;const pending=new Map();
chrome.stdio[4].on('data',chunk=>{buffer+=chunk.toString();let idx;while((idx=buffer.indexOf('\0'))>=0){const msg=JSON.parse(buffer.slice(0,idx));buffer=buffer.slice(idx+1);if(msg.method==='Inspector.targetCrashed'||msg.method==='Target.targetCrashed')console.error(JSON.stringify(msg));if(msg.method==='Runtime.exceptionThrown')runtimeErrors.push(msg.params.exceptionDetails);if(pending.has(msg.id)){const {resolve,reject}=pending.get(msg.id);pending.delete(msg.id);msg.error?reject(Error(JSON.stringify(msg.error))):resolve(msg.result);}}});
function call(method,params={},sessionId){return new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});chrome.stdio[3].write(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})})+'\0');});}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const evalJS=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},session);if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
const deadline=setTimeout(()=>{chrome.kill();process.exitCode=1;console.error('Browser check timed out');},120000);
const results=[],runtimeErrors=[];
try {
 console.log('Browser starting',chrome.pid);await call('Browser.getVersion');console.log('Browser ready'); const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Schnitt'});session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;console.log('Target attached');await call('Runtime.enable',{},session);await sleep(600);console.log('Page loaded');
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);
 const setup=`const r=document.getElementById('ngv-desk'),a=r.ngvTest,q=s=>r.querySelector(s),st=()=>a.state();`;
 const run=code=>evalJS(`(()=>{${setup}${code}})()`);
 async function test(name,code){console.log('CHECK '+name);try{const pass=await run(code);results.push({name,pass:!!pass});console.log((pass?'PASS ':'FAIL ')+name);}catch(e){results.push({name,pass:false,error:e.message.slice(0,1200)});console.log('ERROR '+name+' '+e.message.slice(0,500));}}
 const change=(selector,value)=>run(`{const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.value=${JSON.stringify(String(value))};el.dispatchEvent(new Event('change',{bubbles:true}));}`);
 async function click(selector){const p=await run(`const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing '+${JSON.stringify(selector)});el.scrollIntoView({block:'nearest'});const b=el.getBoundingClientRect();return{x:b.x+b.width/2,y:b.y+b.height/2}`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...p},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...p},session);await sleep(50);}
 async function shot(name){const image=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-studio-'+name+'.png',Buffer.from(image.data,'base64'));}











 const out=path.join(here,'review','tile-spacing-2026-09-20');await mkdir(out,{recursive:true});
 const geometry=[];
 async function scaleUI(scale){await run(`a.action('studio:settings');const el=q('[data-sx="uiScale"]');el.value=${scale};el.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:modal-close');`);}
 async function capture(name){await sleep(100);const pic=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(path.join(out,name+'.png'),Buffer.from(pic.data,'base64'));}
 for(const [width,scale,cols]of [[1048,100,2],[1440,100,3],[1048,130,3],[900,100,2],[768,130,3]]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false},session);
  await run(`a.fixture('Storyboard');a.choose(2);r.style.setProperty('--nd-thumb',${JSON.stringify(String(cols))});`);await scaleUI(scale);
  const result=await run(`const grid=q('.contact-sheet'),tiles=[...grid.querySelectorAll('.shot-tile')],rect=x=>x.getBoundingClientRect();return {width:${width},scale:${scale},requestedColumns:${cols},columns:getComputedStyle(grid).gridTemplateColumns,overflow:grid.scrollWidth>grid.clientWidth,tiles:tiles.map(t=>{const c=t.querySelector('.shot-caption'),b=c.querySelector('b'),name=c.querySelector('span'),duration=c.querySelector('small'),note=t.querySelector('.shot-note'),nr=document.createRange();nr.selectNodeContents(note);return{width:rect(t).width,titleInset:rect(b).left-rect(c).left,idTitleGap:rect(name).left-rect(b).right,titleDurationGap:rect(duration).left-rect(name).right,noteGap:nr.getBoundingClientRect().top-rect(c).bottom,noteBottom:rect(note).bottom-nr.getBoundingClientRect().bottom,titleVisible:getComputedStyle(name).display!=='none',titleWidth:rect(name).width,overflow:t.scrollWidth>t.clientWidth};})};`);
  geometry.push(result);await capture('board-'+width+'-'+scale+'-'+cols);
 }
 await call('Emulation.setDeviceMetricsOverride',{width:1048,height:1000,deviceScaleFactor:1,mobile:false},session);await scaleUI(100);
 await run(`a.fixture('Storyboard');a.choose(2);const before=st(),size=q('.shot-tile[data-shot="2"]').getBoundingClientRect();a.choose(0);const other=q('.shot-tile[data-shot="2"]').getBoundingClientRect();if(size.width!==other.width||size.height!==other.height)throw Error('Selection changes tile geometry');const state=st();state.shots[2].name='Der versperrte Weg zur verlassenen Veranda';a.restore(state);a.choose(2);`);
 await capture('board-long-title');
 await test('Storyboard selection updates Inspector',`a.choose(2);return q('#nd-inspector').textContent.includes('Der versperrte Weg');`);
 await run(`a.fixture('Storyboard');a.choose(4);a.action('mode:moments');`);await capture('moments');
 await test('Sketch moment selection',`q('[data-do="moment:1"]').click();return st().moment===1&&q('[data-do="moment:1"]').getAttribute('aria-pressed')==='true';`);
 await run(`a.fixture('References');const state=st();state.refMode='identities';a.restore(state);`);await capture('references');await test('Reference captions sit below complete images',`return [...r.querySelectorAll('.board-tile')].every(t=>{const image=t.querySelector('.thumb-image').getBoundingClientRect(),title=t.querySelector('b').getBoundingClientRect();return title.top>=image.bottom&&image.width>t.clientWidth-3});`);await scaleUI(130);await capture('references-130');await scaleUI(100);
 await run(`const state=st();state.refMode='anchors';state.refLayout='grid';a.restore(state);`);await capture('anchors');
 await test('Anchor captions sit below images',`return [...r.querySelectorAll('.board-tile')].every(t=>t.querySelector('b').getBoundingClientRect().top>=t.querySelector('.thumb-image').getBoundingClientRect().bottom);`);

 await run(`a.fixture('Takes');`);await capture('takes');await scaleUI(130);await capture('takes-130');await scaleUI(100);
 await run(`a.fixture('Medien');`);await capture('media');await scaleUI(130);await capture('media-130');await scaleUI(100);
 await test('Media selection and list view remain usable',`q('.media-tile').click();a.action('pool:view-list');return st().mediaMarked.length===1&&!!q('.media-list');`);await capture('media-list');
 await run(`a.fixture('Schnitt');`);await capture('picker');
 await test('Source picker stays a compact list',`return [...r.querySelectorAll('.pool .media-tile')].some(el=>el.getBoundingClientRect().height<45);`);
 await run(`a.fixture('Postproduction');const state=st();state.studio.post='review';a.restore(state);`);await capture('postproduction');
 await test('Review filmstrip remains selectable',`const clip=q('[data-do="finish:clip-1"]');if(!clip)return false;clip.click();return st().finish.cursor>0;`);
 await writeFile(path.join(out,'geometry.json'),JSON.stringify(geometry,null,2));await writeFile(path.join(out,'interaction-checks.json'),JSON.stringify({results,runtimeErrors},null,2));
 console.log('Runtime errors',runtimeErrors.length);if(runtimeErrors.length||results.some(x=>!x.pass)||geometry.some(g=>g.overflow||g.tiles.some(t=>t.overflow||!t.titleVisible||t.titleWidth<20||t.noteGap<6||t.titleInset<8)))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}
