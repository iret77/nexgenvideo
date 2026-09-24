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











 const out=path.join(here,'review','shot-context-menu-2026-09-20');await mkdir(out,{recursive:true});
 async function capture(name){await sleep(80);const pic=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(path.join(out,name+'.png'),Buffer.from(pic.data,'base64'));}
 async function rightClick(index){const point=await run(`const el=q('.shot-tile[data-shot="${index}"]');el.scrollIntoView({block:'nearest'});const rect=el.getBoundingClientRect();return {x:rect.left+rect.width/2,y:rect.top+Math.min(40,rect.height/2)};`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'right',buttons:2,clickCount:1,...point},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'right',buttons:0,clickCount:1,...point},session);}
 await run(`a.fixture('Storyboard');a.choose(2);`);await rightClick(2);await capture('single-shot');
 await test('Right-click exposes shot editing and keeps selection',`return !!q('.context-menu [data-do="wf:previous"]')&&!q('.context-menu [data-do="wf:previous"]').disabled&&st().selected[0]===2&&![...q('#nd-inspector').querySelectorAll('summary')].some(e=>e.textContent==='Shotfolge');`);
 await test('Context move, undo and redo preserve shot data',`const before=st().shots; q('.context-menu [data-do="wf:previous"]').click();const after=st().shots;if(after.map(x=>x.id).join(',')!=='1A,1C,1B,1D,1E,1F'||q('.context-menu'))return false;if(before.some(s=>JSON.stringify(s)!==JSON.stringify(after.find(x=>x.id===s.id))))return false;a.action('undo');if(st().shots.map(x=>x.id).join(',')!=='1A,1B,1C,1D,1E,1F')return false;a.action('redo');return st().shots[1].id==='1C';`);
 await run(`a.fixture('Storyboard');a.choose(1);a.choose(3,true);`);await rightClick(3);await capture('multiple-shots');
 await test('Context click preserves a multi-selection',`return st().selected.join(',')==='1,3'&&q('.context-menu [data-do="wf:rename"]').disabled;`);
 await test('Multiple shots move one place without reversing order',`q('.context-menu [data-do="wf:previous"]').click();return st().shots.map(s=>s.id).join(',')==='1B,1A,1D,1C,1E,1F'&&st().selected.map(i=>st().shots[i].id).join(',')==='1B,1D';`);
 await run(`a.fixture('Storyboard');a.choose(0);`);await rightClick(0);
 await test('Boundary moves are disabled and no-op commands do not revise',`const version=st().version;if(!q('[data-shot-command][data-do="wf:previous"]').disabled||!q('[data-shot-command][data-do="wf:first"]').disabled)return false;a.action('wf:previous');return st().version===version;`);
 await test('Escape closes menu and returns focus',`q('.context-menu button:not(:disabled)').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return !q('.context-menu')&&document.activeElement?.dataset.shot==='0';`);
 await run(`a.fixture('Storyboard');a.choose(2);`);await rightClick(2);
 await test('Rename opens and focuses the existing shot property',`q('.context-menu [data-do="wf:rename"]').click();const input=q('[data-field="name"]');return !!input&&document.activeElement===input&&input.closest('details').open&&!q('.context-menu');`);await capture('name-property');
 await test('Rename field persists the selected shot name',`const input=q('[data-field="name"]');input.value='Neuer Shotname';input.dispatchEvent(new Event('change',{bubbles:true}));return st().shots[2].name==='Neuer Shotname';`);
 await run(`a.fixture('Schnitt');a.action('open:board');a.choose(2);`);await rightClick(2);await capture('approved-storyboard');
 await test('Approved Storyboard remains locked',`return ['wf:previous','wf:next','wf:rename','wf:split','wf:delete'].every(cmd=>q('.context-menu [data-do="'+cmd+'"]').disabled)&&!q('.context-menu [data-do="revise"]').disabled&&[...r.querySelectorAll('[data-board-drag]')].every(el=>!el.draggable);`);
 await test('Revision still asks before changing approved work',`const before=st().shots.map(s=>s.id).join(',');q('.context-menu [data-do="revise"]').click();return st().modal==='rewind'&&st().done.board&&st().shots.map(s=>s.id).join(',')===before&&!q('.context-menu');`);
 await run(`a.action('close');a.fixture('Storyboard');a.choose(1);q('.shot-tile[data-shot="1"]').focus();a.action('native:menu-edit');`);await capture('edit-menu');
 await test('Menu-bar move uses the same operation',`q('#nd-native-menu [data-do="wf:last"]').click();return st().shots.at(-1).id==='1B'&&!st().modal;`);
 await run(`a.fixture('Storyboard');a.choose(1);a.choose(2,true);const dt=new DataTransfer();window.ngvDragData=dt;q('[data-board-drag="1"]').dispatchEvent(new DragEvent('dragstart',{bubbles:true,dataTransfer:dt}));const target=q('[data-board-drag="4"]'),rect=target.getBoundingClientRect();target.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:dt,clientX:rect.right-2,clientY:rect.top+30}));`);await capture('drag-insertion');
 await test('Dragging previews and inserts the selected group at the marked edge',`if(!q('.board-drop-marker'))return false;const target=q('[data-board-drag="4"]'),rect=target.getBoundingClientRect();target.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:window.ngvDragData,clientX:rect.right-2,clientY:rect.top+30}));return st().shots.map(s=>s.id).join(',')==='1A,1D,1E,1B,1C,1F'&&!q('.board-drop-marker')&&st().selected.map(i=>st().shots[i].id).join(',')==='1B,1C';`);
 await test('Cancelled drag leaves order and revision intact',`const before=JSON.stringify(st().shots),version=st().version,dt=new DataTransfer(),tile=q('[data-board-drag="0"]');tile.dispatchEvent(new DragEvent('dragstart',{bubbles:true,dataTransfer:dt}));tile.dispatchEvent(new DragEvent('dragend',{bubbles:true,dataTransfer:dt}));return JSON.stringify(st().shots)===before&&st().version===version&&!q('.board-drop-marker')&&!q('.board-dragging');`);
 await run(`a.fixture('Storyboard');a.choose(2);const tile=q('.shot-tile[data-shot="2"]'),rect=tile.getBoundingClientRect();tile.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,ctrlKey:true,clientX:rect.left+30,clientY:rect.top+30}));`);
 await test('Control-click opens the context menu',`return !!q('.context-menu');`);
 await test('Menu arrow navigation does not move the shot selection',`const old=document.activeElement,selected=st().selected.join(',');old.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));return document.activeElement!==old&&st().selected.join(',')===selected;`);
 await test('Click outside closes the menu',`q('#nd-canvas').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));return !q('.context-menu');`);
 await run(`a.action('studio:settings');const input=q('[data-sx="uiScale"]');input.value=130;input.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:modal-close');const tile=q('.shot-tile[data-shot="2"]'),rect=r.getBoundingClientRect();tile.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,clientX:rect.right-2,clientY:rect.bottom-2}));`);await capture('menu-edge-130');
 await test('Context menu stays inside the app window at 130 percent',`const menu=q('.context-menu').getBoundingClientRect(),box=r.getBoundingClientRect();return menu.left>=box.left&&menu.top>=box.top&&menu.right<=box.right&&menu.bottom<=box.bottom;`);
 await writeFile(path.join(out,'checks.json'),JSON.stringify({results,runtimeErrors},null,2));console.log('Runtime errors',runtimeErrors.length);if(runtimeErrors.length||results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}
