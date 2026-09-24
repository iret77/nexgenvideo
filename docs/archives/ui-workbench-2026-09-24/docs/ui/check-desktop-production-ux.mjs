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

 await test('Status bar contains project context, no prototype badge or fixture control',`for(const v of ['Medien','Storyboard','Schnitt','Postproduction','Export']){a.fixture(v);if(q('#nd-status').textContent.includes('CLICKDUMMY')||q('[data-demo]'))return false;}return q('#nd-status').textContent.includes('Budget')`);
 await test('Footer does not duplicate workspace switching',`a.fixture('Schnitt');return !q('#nd-status [data-do^="workspace:"]')`);
 await test('Transcript scope and placeholder use consistent wording',`a.fixture('Medien');a.action('studio:search-spoken');return q('[data-search-scope] option:checked').textContent==='Transkript'&&q('[data-media-search]').placeholder==='Transkript durchsuchen'`);
 await test('Transcript search does not match filenames or text documents',`let s=st();s.mediaImports.push({id:'speech-fixture',name:'Banane.mov',type:'video',folder:'imports',transcript:[{in:1,out:3,text:'Die Maschine läuft'}]},{id:'text-fixture',name:'Dialog.txt',type:'text',content:'Die Maschine läuft'});s.mediaQuery='Banane';a.restore(s);return !q('[data-do="asset:speech-fixture"]')&&!q('[data-do="asset:text-fixture"]')`);
 await test('Transcript hit uses recorded text and time range',`let e=q('[data-media-search]');e.value='Maschine';e.dispatchEvent(new Event('input',{bubbles:true}));return !!q('[data-do="studio:moment-speech-fixture~0"]')&&!q('[data-do="asset:text-fixture"]')`);
 await click('[data-do="studio:moment-speech-fixture~0"]');
 await test('Search hit keeps media workspace and source context',`return st().view==='media'&&st().mediaSelection==='speech-fixture'&&st().studio.sourceIn===1&&st().studio.sourceOut===3`);
 await test('Still-image search has no fabricated time range',`a.fixture('Medien');a.action('studio:search-moments');let e=q('[data-media-search]');e.value='Maus';e.dispatchEvent(new Event('input',{bubbles:true}));return !q('.studio-search-detail').textContent.includes('00:01')&&!q('[data-do="asset:take-0-1"]')&&!!q('[data-do="asset:take-1-1"]')`);
 await test('Clip selection synchronizes preview and inspector',`a.fixture('Schnitt');const c=st().nle.clips.find(c=>c.shot===3);a.nleSelect(c.id);return st().nle.cursor===c.start&&q('#nd-inspector').textContent.includes('1D')&&q('.studio-viewer-note').textContent.includes('1D')`);
 await test('Audio selection exposes audio parameters only',`a.nleSelect('track-song');return !!q('[data-sx="clip-gain"]')&&!q('[data-sx="clip-rotation"]')&&!q('[data-do="nle:tab-adjust"]')&&q('[data-sx="keyParam"]').options.length===1`);
 await test('Postproduction audio selection switches tool context',`a.action('workspace:post');a.nleSelect('track-song');return st().studio.post==='audio'&&q('#nd-surface-tools').textContent.includes('Audio')`);
 await test('Timeline dragstart is not cancelled by storyboard handler',`a.fixture('Schnitt');const el=q('[data-sx-clip]'),e=new DragEvent('dragstart',{bubbles:true,cancelable:true,dataTransfer:new DataTransfer()});el.dispatchEvent(e);const ok=!e.defaultPrevented&&e.dataTransfer.getData('application/x-ngv-clip')===el.dataset.sxClip;el.dispatchEvent(new DragEvent('dragend',{bubbles:true}));return ok`);
 await test('Muted track is reflected in Export and end review',`a.action('studio:track-hide-A1');a.action('workspace:finish');const matches=q('#nd-inspector').textContent.includes('Stumm');a.action('studio:post-review');a.action('finish:scan');return matches&&st().finish.findings.some(f=>f.id==='muted')`);
 await test('Text-to-video profile does not offer unsupported source slots',`a.fixture('Medien');a.action('gen:open');a.action('gen:type-video');return !q('[data-sx="generationMode"]')&&!q('[data-sx="generationSource"]')&&!q('[data-generation="reference"]')`);
 await test('Online asset cannot be relinked and imported asset cannot reuse absent prompt',`a.fixture('Medien');return q('[data-do="studio:asset-relink"]').disabled&&!q('[data-do="studio:asset-generate"]')`);
 await test('Export stores historical fps',`a.fixture('Export');a.action('finish:export');a.action('finish:start-export');a.action('finish:cancel');return st().finish.exports.at(-1).fps===24`);
 await test('Export history does not borrow current project fps',`let s=st();s.studio.fps=30;s.finishSection='history';a.restore(s);return q('#nd-inspector').textContent.includes('24 fps')&&!q('#nd-inspector').textContent.includes('30 fps')`);
 for(const view of ['Medien','Audio','Storyboard','Schnitt','Postproduction','Export']){await run(`a.fixture('${view}')`);const bounds=await run(`const b=r.getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height,scale:1}`);const img=await call('Page.captureScreenshot',{format:'png',clip:bounds,captureBeyondViewport:true},session);await writeFile(path.join(here,'review/studio-screenshots/ux-'+view.toLowerCase()+'.png'),Buffer.from(img.data,'base64'));}
 await writeFile(path.join(here,'review/studio-ux-checks.json'),JSON.stringify({results},null,2));console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,failed:results.filter(x=>!x.pass)}));if(results.some(x=>!x.pass))process.exitCode=1;
} finally {clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
