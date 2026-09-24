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





 await test('Gate names viewed phase before revision',`a.fixture('Storyboard');a.action('open:brief');return q('#nd-gate b').textContent.startsWith('Briefing · freigegeben')&&q('[data-do=revise]').textContent.includes('Briefing')`);
 await test('Revision dialog names the same target',`a.action('revise');return q('#nd-dialog-title').textContent.includes('Briefing')`);
 await test('Planning cannot mutate approved timing or action',`a.fixture('Shotplanung');const before=JSON.stringify(st().shots);a.editField({dataset:{field:'duration'},value:'8'});a.editField({dataset:{field:'action'},value:'Changed'});return !q('[data-field=duration]')&&!q('[data-field=action]')&&JSON.stringify(st().shots)===before&&st().done.board`);
 await test('Storyboard edit opens explicit rewind without changing approvals',`a.action('revise-board');return st().modal==='rewind'&&st().view==='board'&&st().done.board&&st().current==='plan'`);
 await test('Confirmed timing revision invalidates downstream',`a.action('confirm-rewind');a.editField({dataset:{field:'duration'},value:'4'});return !st().done.board&&!st().done.plan&&st().current==='board'&&st().shots[0].duration===4`);
 await test('Planning list contains no duplicate shot strip',`a.fixture('Shotplanung');return !q('.sequence-dock')`);
 await test('Blocking shot chooser has no transport',`a.fixture('Blocking');a.action('clay:view-space');return !!q('.clay-shotbar')&&!q('.clay-transport')&&!q('.playhead')&&!q('#nd-time')&&!q('[data-scrub]')`);
 await test('References show rendered image by default',`a.fixture('References');return !!q('.reference-viewer .reference')&&!q('.compare')&&!q('#nd-canvas .sketch')`);
 await test('Sketch comparison is optional and leaves approvals unchanged',`const before=JSON.stringify(st().done);a.action('ref-compare');const ok=!!q('.wf-source-comparison')&&q('.wf-source-comparison').innerText.includes('Storyboard');a.action('ref-compare');return ok&&!q('.wf-source-comparison')&&JSON.stringify(st().done)===before`);
 await test('Postproduction has no invisible trim controls or duplicate clip list',`a.fixture('Postproduction');return !q('.nle-trim')&&!q('.studio-clip-list')`);
 await test('Inspector tabs fit one icon row',`a.fixture('Schnitt');const tabs=[...r.querySelectorAll('.inspector-tabs button')];return tabs.length===6&&new Set(tabs.map(b=>b.getBoundingClientRect().top)).size===1&&tabs.every(b=>b.getAttribute('aria-label')&&b.querySelector('svg'))`);
 await test('Inspector header stays put while its body scrolls',`const h=q('.inspector-header').getBoundingClientRect().top;q('.inspector-scroll').scrollTop=400;return q('.inspector-header').getBoundingClientRect().top===h&&q('.inspector-scroll').scrollTop>0`);
 await test('Export action belongs to output dock, not status',`a.fixture('Export');return !!q('#nd-gate [data-do="finish:export"]')&&!q('#nd-gate').hidden&&!q('#nd-status [data-do="finish:export"]')`);
 await test('Export history does not start a different output',`a.action('finish-section:history');return q('#nd-gate').hidden&&!q('#nd-status [data-do="finish:export"]')`);
 await test('Media retains all search scopes inside search field',`a.fixture('Medien');const x=q('[data-search-scope]');return x.options.length===3&&!q('.studio-search-tabs')&&!q('.library-path')`);
 await test('Transcript scope actually controls search',`const x=q('[data-search-scope]');x.value='spoken';x.dispatchEvent(new Event('change',{bubbles:true}));return st().studio.search==='spoken'&&q('[data-media-search]').getAttribute('aria-label')==='Transkript durchsuchen'`);
 await test('Storyboard selection is visible after opening and rerendering',`a.fixture('Storyboard');a.render();const tile=q('.shot-tile[aria-pressed=true]').getBoundingClientRect(),box=q('#nd-canvas').getBoundingClientRect();return tile.top>=box.top&&tile.bottom<=box.bottom`);
 await test('Scene selection is distinct from shot selection',`a.fixture('Storyboard');a.action('open:script');return q('.inspector-header b').textContent==='Szene 1'&&!!q('[data-do="segment:0"][aria-pressed=true]')`);
 await test('Returning from a scene restores the selected shot',`a.action('segment:1');a.action('open:board');return st().selected[0]===4`);
 await test('Text focus updates the document inspector without changing shot selection',`a.action('open:script');q('[data-field="doc:2"]').dispatchEvent(new FocusEvent('focusin',{bubbles:true}));return q('.inspector-header b').textContent==='Szene 3'&&st().selected[0]===4`);
 await test('Revised scene alternative stays inside its document',`a.action('revise');a.action('confirm-rewind');a.action('alternative');a.action('ux:creative-preview');const proposal=q('.dialog').textContent;a.action('ux:creative-apply');return proposal.includes('Klarer')&&st().docs.script.length===3&&st().docs.script.every(x=>typeof x==='string'&&x.trim())&&st().selected[0]===4`);
 await test('Postproduction hints describe available actions',`a.fixture('Postproduction');return !q('[data-nle-edit-note]').textContent.includes('trimmen')&&q('[data-nle-edit-note]').textContent.includes('Inspector')`);
 for(const fixture of ['Medien','Audio','Storyboard','Shotplanung','References','Review','Takes','Schnitt','Postproduction','Export']){
  await test('Shared pane height: '+fixture,`a.fixture(${JSON.stringify(fixture)});const h=s=>q(s).getBoundingClientRect().height;return h('.inspector-header')===40&&h('#nd-surface-tools')===40&&q('#nd-browser .sidebar-tabs,#nd-browser .library-nav-head,#nd-browser .pane-heading').getBoundingClientRect().bottom===q('#nd-surface-tools').getBoundingClientRect().bottom`);
 }
 await writeFile(here+'/review/polish-2026-09-19/polish-checks.json',JSON.stringify(results,null,2));
 console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,failed:results.filter(x=>!x.pass)}));if(results.some(x=>!x.pass))process.exitCode=1;
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
