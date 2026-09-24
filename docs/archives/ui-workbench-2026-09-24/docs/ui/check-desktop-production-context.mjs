import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir, rm} from 'node:fs/promises';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
const here=path.dirname(fileURLToPath(import.meta.url));
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











 const out=path.join(here,'review','all-context-menus-2026-09-20');await mkdir(out,{recursive:true});
 const open=async selector=>run(`const el=q(${JSON.stringify(selector)});if(!el)throw Error('Missing target');el.scrollIntoView({block:'nearest'});const b=el.getBoundingClientRect();el.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,clientX:b.left+20,clientY:b.top+20}));return [...r.querySelectorAll('.object-menu button')].map(b=>({cmd:b.dataset.do,label:b.textContent,disabled:b.disabled}));`);
 const close=()=>run(`a.action('close');`);
 const fixture=name=>run(`a.action('close');a.fixture(${JSON.stringify(name)});`);
 async function capture(name){await sleep(100);const pic=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile(path.join(out,name+'.png'),Buffer.from(pic.data,'base64'));}
 const matrix=[];
 for(const [fixtureName,selector]of [['Medien','[data-do^="asset:"]'],['Medien','[data-do^="pool:folder-"]:not([data-do="pool:folder-all"])'],['Storyboard','.shot-tile'],['Storyboard','[data-do="moment:0"]'],['Shotplanung','[data-shot]'],['References','[data-do="studio:entity-0"]'],['Takes','[data-take]'],['Blocking','[data-do^="clay:object-"]'],['Blocking','[data-do^="clay:shot-"]'],['Blocking','.clay-stage canvas'],['Audio','[data-section]'],['Schnitt','[data-sx-clip]'],['Schnitt','[data-do="studio:track-V1"]'],['Postproduction','[data-sx-clip]']]){
  await fixture(fixtureName);if(fixtureName==='References')await run(`a.action('ref:identities');`);if(selector.includes('moment:'))await run(`a.action('mode:moments');`);try{const items=await open(selector);matrix.push({fixture:fixtureName,selector,items});await test(fixtureName+' contextual actions: '+selector,`const menu=q('.object-menu');return !!menu&&[...menu.querySelectorAll('button')].every(b=>b.getAttribute('role')?.startsWith('menuitem'))&&!menu.textContent.includes('undefined');`);await capture(fixtureName.toLowerCase()+'-'+matrix.length);}catch(e){results.push({name:'Context '+fixtureName+' '+selector,pass:false,error:e.message});}
 }
 await writeFile(path.join(out,'inventory.json'),JSON.stringify(matrix,null,2));
 await fixture('Medien');await run(`a.action('studio:import-demo');const ids=st().mediaImports.map(x=>x.id);window.testMediaIDs=ids.slice(0,2);q('[data-do="asset:'+ids[0]+'"]').click();q('[data-do="asset:'+ids[1]+'"]').dispatchEvent(new MouseEvent('click',{bubbles:true,metaKey:true}));`);
 const mediaId=await run('return window.testMediaIDs[1];');await open('[data-do="asset:'+mediaId+'"]');
 await test('Media context preserves multi-selection; single-file commands disabled',`return st().mediaMarked.length===2&&q('[data-do="object:studio:asset-rename"]').disabled&&q('[data-do="object:studio:asset-path"]').disabled&&!q('[data-do="object:pool:move"]').disabled;`);await capture('media-multi');
 await test('Media move opens the folder chooser for the same selection',`q('[data-do="object:pool:move"]').click();return st().modal==='pool-move'&&st().mediaMarked.length===2&&!!q('#nd-folder-target');`);
 await close();await open('[data-do="asset:sketch-0-0"]');
 await test('Workflow-owned assets cannot be removed through library context',`return q('[data-do="object:studio:asset-delete"]').disabled;`);
 await fixture('Storyboard');await run(`a.choose(1);a.choose(3,true);`);await open('.shot-tile[data-shot="3"]');
 await test('Storyboard multi-selection retains shared reorder and undo',`if(st().selected.join(',')!=='1,3'||!q('[data-do="object:wf:rename"]').disabled)return false;q('[data-do="object:wf:previous"]').click();if(st().shots.map(s=>s.id).join(',')!=='1B,1A,1D,1C,1E,1F')return false;a.action('undo');return st().shots.map(s=>s.id).join(',')==='1A,1B,1C,1D,1E,1F';`);
 await fixture('Schnitt');await run(`const ids=st().nle.clips.filter(x=>x.type!=='audio').slice(0,2).map(x=>x.id);window.testClips=ids;a.nleSelect(ids[0]);a.nleSelect(ids[1],null,true);`);const clipID=await run('return window.testClips[1];');await open('[data-sx-clip="'+clipID+'"]');
 await test('Timeline right-click keeps both clips; only applicable actions enabled',`return st().nle.marked.length===2&&q('[data-do="object:nle:split"]').disabled&&q('[data-do="object:studio:swap"]').disabled&&!q('[data-do="object:studio:copy"]').disabled;`);await capture('timeline-multi');
 await test('Copy command acts on the whole timeline selection',`q('[data-do="object:studio:copy"]').click();return st().studio.clipboard.length===2&&!st().modal;`);
 await run(`const s=st();s.nle.tracks.find(t=>t.id==='V1').lock=true;a.restore(s);`);await open('[data-sx-clip="'+clipID+'"]');
 await test('Locked track disables destructive and partial edits',`return ['studio:delete','studio:duplicate','nle:split','studio:swap'].every(x=>q('[data-do="object:'+x+'"]').disabled);`);await capture('locked-clip');
 await close();await open('[data-do="studio:track-V1"]');
 await test('Track check state reflects lock; occupied track cannot be removed',`return q('[data-do="object:studio:track-lock-V1"]').getAttribute('aria-checked')==='true'&&q('[data-do="object:studio:track-remove"]').disabled;`);
 await test('Unlock through context updates the selected track',`q('[data-do="object:studio:track-lock-V1"]').click();return !st().nle.tracks.find(t=>t.id==='V1').lock;`);
 await fixture('Schnitt');await run(`a.action('studio:title-add');`);await open('.nle-title-clip');
 await test('Title has title actions, not clip commands',`return !!q('[data-do="object:studio:title-delete"]')&&!q('[data-do="object:studio:swap"]');`);await capture('title');
 await fixture('Schnitt');await run(`a.action('open:board');`);await open('.shot-tile');
 await test('Approved board exposes explicit revision, keeps edits locked',`return q('[data-do="object:wf:delete"]').disabled&&!q('[data-do="object:revise"]').disabled;`);
 await fixture('Storyboard');await open('.shot-tile');
 await test('Escape restores object focus; arrow keys stay in menu',`const selected=st().selected.join(','),first=document.activeElement;first.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));if(first===document.activeElement||selected!==st().selected.join(','))return false;document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));return !q('.object-menu')&&document.activeElement?.dataset.shot==='0';`);
 await test('Keyboard context-menu key works',`q('.shot-tile').dispatchEvent(new KeyboardEvent('keydown',{key:'F10',shiftKey:true,bubbles:true,cancelable:true}));return !!q('.object-menu');`);
 await close();await test('Control-click works for folders too',`const el=q('[data-do="workspace:media"]');a.action('workspace:media');const folder=q('[data-do="pool:folder-all"]'),b=folder.getBoundingClientRect();folder.dispatchEvent(new MouseEvent('click',{ctrlKey:true,bubbles:true,cancelable:true,clientX:b.x+20,clientY:b.y+12}));return !!q('.object-menu [data-do="object:pool:new"]');`);
 await fixture('Storyboard');await run(`a.choose(2);q('.shot-tile[data-shot="2"]').focus();a.action('native:menu-edit');`);
 await test('Menu bar uses the same commands without duplicate entries',`const items=[...r.querySelectorAll('#nd-native-menu button')],ids=items.map(x=>x.dataset.do);return !!q('#nd-native-menu [data-do="object:wf:previous"]')&&new Set(ids).size===ids.length&&!q('#nd-native-menu').textContent.includes('undefined');`);await capture('edit-menu');
 await test('Menu bar reorders the intended shot',`q('#nd-native-menu [data-do="object:wf:previous"]').click();return st().shots[1].id==='1C';`);
 await fixture('Schnitt');await run(`a.action('studio:settings');const el=q('[data-sx="uiScale"]');el.value=130;el.dispatchEvent(new Event('change',{bubbles:true}));a.action('studio:modal-close');`);await open('[data-sx-clip]');await capture('scaled-clip');
 await test('Menus fit visible window at 130 percent and scroll when needed',`const m=q('.object-menu').getBoundingClientRect(),b=r.getBoundingClientRect();return m.left>=Math.max(0,b.left)&&m.right<=Math.min(innerWidth,b.right)&&m.top>=0&&m.bottom<=Math.min(innerHeight,b.bottom);`);
 await close();await test('Text fields retain the system context menu',`const el=q('[data-sx="clip-scale"]')||q('input');const event=new MouseEvent('contextmenu',{bubbles:true,cancelable:true});el.dispatchEvent(event);return !event.defaultPrevented&&!q('.object-menu');`);

 await fixture('References');await run(`a.action('wf:refs-layout');`);await open('.board-tile[data-shot="2"]');
 await test('Anchor context compares the clicked shot without approving it',`const old=st().anchorAccepted.join(',');q('[data-do="object:wf:refs-compare"]').click();return st().selected[0]===2&&st().referenceCompare&&st().refLayout==='viewer'&&old===st().anchorAccepted.join(',');`);await capture('anchor-comparison');
 await fixture('Takes');await open('[data-take="2"][data-take-shot="4"]');
 await test('Take context opens exact shot and variant without a decision',`const chosen=JSON.stringify(st().chosen);q('[data-do="object:inspect-take"]').click();return st().selected[0]===4&&st().studio.takeFocus===2&&st().takeViewer&&JSON.stringify(st().chosen)===chosen;`);await capture('take-inspection');
 await fixture('Blocking');await run(`a.action('clay:derive');`);await open('[data-do^="clay:output-"]');
 await test('Clay output menu binds confirmation to the clicked shot',`window.clayReviewedID=st().shots[st().selected[0]].id;return !q('[data-do="object:clay:accept"]').disabled;`);await capture('clay-output');
 await test('Clay confirmation preserves other outputs',`const old=st().clay.outputs;q('[data-do="object:clay:accept"]').click();return st().clay.outputs[window.clayReviewedID].accepted&&Object.keys(old).filter(id=>id!==window.clayReviewedID).every(id=>old[id].accepted===st().clay.outputs[id].accepted);`);
 await fixture('Schnitt');await run(`a.action('studio:key-add');`);await open('[data-do="studio:key-0"]');
 await test('Keyframe delete removes only that key, undo restores it',`const n=st().nle.clips.find(c=>c.id===st().nle.selected).keys.length;q('[data-do="object:studio:key-delete"]').click();if(st().nle.clips.find(c=>c.id===st().nle.selected).keys.length!==n-1)return false;a.action('undo');return st().nle.clips.find(c=>c.id===st().nle.selected).keys.length===n;`);
 await fixture('Schnitt');await open('[data-do="asset:take-1-2"]');
 await test('Compact source picker offers placement, not library management',`return !!q('[data-do="object:studio:insert"]')&&!q('[data-do="object:pool:move"]')&&!q('[data-do="object:studio:asset-delete"]')&&!q('[data-do="object:studio:asset-rename"]');`);await capture('source-picker');
 await close();await open('[data-do="asset:take-1-2"]');await test('Reveal command preserves exact source in the library',`q('[data-do="object:pool:reveal"]').click();return st().view==='media'&&st().mediaSelection==='take-1-2'&&st().mediaMarked.join(',')==='take-1-2';`);
 await fixture('Schnitt');await run(`a.action('workspace:post');a.action('studio:post-review');a.action('finish:scan');`);await open('[data-do^="finish:finding-"]');
 await test('Review finding menu keeps acceptance behind an explicit decision',`return !!q('[data-do="object:finish:accept-finding"]')&&!!q('[data-do="object:finish:repair"]')&&!q('[data-do="object:studio:delete"]');`);await capture('review-finding');
 await fixture('Export');await run(`a.action('finish:export');`);await test('Export setup is reachable for history verification',`return !!q('[data-do="finish:start-export"]')&&!q('[data-do="finish:start-export"]').disabled;`);await run(`a.action('finish:start-export');`);await sleep(1400);await open('[data-do^="finish:export-"]');
 await test('Finished export context has details and new output, no fake Finder or cancel',`return !!q('[data-do="object:inspect"]')&&!!q('[data-do="object:finish-section:delivery"]')&&!q('[data-do="object:finish:cancel"]');`);await capture('export-history');
 await fixture('Medien');await open('[data-do="pool:folder-documents"]');
 await test('Folder rename dialog operates on the clicked folder',`q('[data-do="object:pool:rename"]').click();const input=q('#nd-folder-name');input.value='Projekttexte';input.dispatchEvent(new Event('input',{bubbles:true}));q('[data-do="pool:save-folder"]').click();return st().mediaFolderNames.documents==='Projekttexte';`);
 await fixture('Storyboard');await test('Select-all shortcut selects the storyboard, not browser text',`q('.shot-tile').dispatchEvent(new KeyboardEvent('keydown',{key:'a',metaKey:true,bubbles:true,cancelable:true}));return st().selected.length===st().shots.length;`);
 await fixture('Schnitt');await run(`const s=st();s.nle.selected=null;s.nle.marked=[];a.restore(s);`);await open('.nle-lane');
 await test('Empty timeline menu offers sequence actions without clip deletion',`return !!q('[data-do="object:studio:add-track"]')&&!q('[data-do="object:studio:delete"]');`);
 await fixture('Medien');await open('[data-do="asset:take-0-1"]');await test('Menu dismissal consumes the click without activating workspace underneath',`const button=q('[data-do="workspace:edit"]');button.dispatchEvent(new PointerEvent('pointerdown',{button:0,bubbles:true,cancelable:true}));button.dispatchEvent(new MouseEvent('click',{button:0,bubbles:true,cancelable:true}));return st().view==='media'&&!q('.object-menu');`);
 await fixture('Storyboard');await open('.shot-tile');await test('Disabled commands cannot mutate state even if dispatched directly',`const before=JSON.stringify(st().shots);a.action('object:wf:previous');return JSON.stringify(st().shots)===before;`);
 await fixture('Storyboard');await open('.shot-tile[data-shot="2"]');await test('No menu overlays survive a workspace change',`a.action('workspace:media');return !st().modal&&!q('.object-menu');`);
 await fixture('Schnitt');const p=await run(`const el=q('[data-sx-clip]');const b=el.getBoundingClientRect();window.actualClip=el.dataset.sxClip;return {x:b.left+20,y:b.top+20};`);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'right',buttons:2,clickCount:1,...p},session);await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'right',buttons:0,clickCount:1,...p},session);
 await test('Real mouse right-click selects the target and opens its menu',`return !!q('.object-menu')&&st().nle.selected===window.actualClip;`);await capture('real-timeline-context');
 await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27},session);await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Escape',code:'Escape',windowsVirtualKeyCode:27},session);
 await test('Real Escape closes menu and returns keyboard focus',`return !q('.object-menu')&&document.activeElement?.dataset.sxClip===window.actualClip;`);

 await fixture('Postproduction');await run(`a.action('studio:post-review');`);await open('[data-do="finish:clip-2"]');
 await test('Filmstrip context reveals the exact timeline clip',`const id=st().nle.clips.filter(c=>c.type!=='audio').sort((a,b)=>a.start-b.start)[2].id;q('[data-do="object:clip-in-edit"]').click();return st().view==='edit'&&st().nle.selected===id&&document.activeElement?.dataset.sxClip===id;`);
 await fixture('Medien');await run(`a.action('studio:search-moments');const el=q('[data-media-search]');el.value='Maus';el.dispatchEvent(new Event('input',{bubbles:true}));`);await open('[data-do^="studio:moment-"]');
 await test('Content search results use media commands for the matched asset',`return !!q('.object-menu [data-do="object:studio:asset-path"]')&&st().mediaSelection&&st().mediaMarked.includes(st().mediaSelection);`);await capture('search-result');
 await fixture('Blocking');await test('Control-click in 3D does not start a drag or change geometry',`const before=JSON.stringify(st().clay.locations),el=q('.clay-stage canvas'),b=el.getBoundingClientRect();el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,button:0,ctrlKey:true,clientX:b.left+30,clientY:b.top+30,pointerId:1}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,button:0,ctrlKey:true,clientX:b.left+30,clientY:b.top+30}));return !!q('.object-menu')&&JSON.stringify(st().clay.locations)===before;`);
 await fixture('Storyboard');await run(`a.choose(0);q('.shot-tile[data-shot="0"]').focus();`);await sleep(120);
 const dragPoints=await run(`const src=q('[data-board-drag="0"]').getBoundingClientRect(),dest=q('[data-board-drag="2"]').getBoundingClientRect();return {start:{x:src.left+src.width/2,y:src.top+40},end:{x:dest.right-12,y:dest.top+40}};`);
 await call('Input.dispatchMouseEvent',{type:'mouseMoved',...dragPoints.start},session);await call('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',buttons:1,clickCount:1,...dragPoints.start},session);
 for(let i=1;i<=12;i++){await call('Input.dispatchMouseEvent',{type:'mouseMoved',button:'left',buttons:1,x:dragPoints.start.x+(dragPoints.end.x-dragPoints.start.x)*i/12,y:dragPoints.start.y+(dragPoints.end.y-dragPoints.start.y)*i/12},session);await sleep(20);}
 await test('Real drag still displays the insertion marker',`return !!q('.board-drop-marker')&&!!q('.board-dragging');`);await capture('drag-insertion');
 await call('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',buttons:0,clickCount:1,...dragPoints.end},session);await sleep(80);
 await test('Real drag keeps its exact destination after menu refactoring',`return st().shots.map(s=>s.id).join(',')==='1B,1C,1A,1D,1E,1F'&&!q('.board-drop-marker');`);
 await test('Inspector layout remains a single scroller with no orphan sections',`const panel=q('#nd-inspector');return panel.querySelectorAll(':scope > .inspector-scroll').length===1&&!panel.querySelector(':scope > details.inspector-group')&&!panel.querySelector('.inspector-scroll .inspector-scroll');`);
 await writeFile(path.join(out,'checks.json'),JSON.stringify({results,runtimeErrors},null,2));console.log('Runtime errors',runtimeErrors.length);if(runtimeErrors.length||results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}
