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
 await test('Timeline has visible clips and nonzero width',`return q('.nle-content').getBoundingClientRect().width>300&&r.querySelectorAll('[data-sx-clip]').length===7`);await shot('edit');
 await test('Empty project permits free editing',`a.fixture('Leer','Generic');a.action('workspace:edit');return !st().done.takes&&q('.nle-empty')!==null`);
 await click('[data-do="studio:import-demo"]');
 await test('All supported source types imported',`return st().mediaImports.length===5`);
 for(const type of ['video','image','lottie','audio']) await test('Insert free '+type,`const id=st().mediaImports.find(x=>x.type==='${type}').id;a.action('asset:'+id);a.action('studio:insert');return st().nle.clips.some(c=>c.asset===id)`);
 await test('Free export without pipeline approval',`a.action('workspace:finish');return !q('[data-do="finish:export"]').disabled&&!st().done.takes`);
 await click('[data-do="finish:export"]');await click('[data-do="finish:start-export"]');await sleep(1450);
 await test('Free export completes',`return st().finish.exports.at(-1).status==='complete'`);
 await test('Separate Postproduction workspace',`a.fixture('Postproduction');return st().view==='post'&&q('[data-do="studio:post-color"]')&& !q('[data-do="finish:export"]')`);
 await change('[data-grade="exposure"]',1);
 await run(`q('[data-grade="exposure"]').dispatchEvent(new Event('input',{bubbles:true}));`);
 await test('Grade is shared with timeline',`return st().nle.clips[0].exposure===1`);
 await click('[data-do="studio:grade-curves"]');await change('[data-sx="curve-2"]',65);
 await test('Curves retain editable points',`return st().nle.clips[0].fx.curveRGB[2]===65`);await shot('curves');
 await click('[data-do="studio:grade-wheels"]');await change('[data-sx="fx-wheelHue0"]',160);
 await test('Color wheels retain hue',`return st().nle.clips[0].fx.wheelHue0===160`);
 await test('Undo restores prior grade',`a.action('undo');return st().nle.clips[0].fx.wheelHue0===undefined`);
 await click('[data-do="studio:post-audio"]');await change('[data-sx="clip-fadeIn"]',.5);
 await test('Per-clip audio fade',`return st().nle.clips[0].fadeIn===.5`);
 await test('Keyframe insertion',`a.action('studio:key-add');return st().nle.clips[0].keys.length===1`);
 await click('[data-do="studio:post-captions"]');await click('[data-do="studio:captions"]');await click('[data-do="studio:task-preview"]');await click('[data-do="studio:task-accept"]');
 await test('Captions become editable timeline titles',`return st().nle.titles.length===2&&st().nle.titles[0].caption`);await click('[data-do="studio:task-close"]');
 await click('[data-do="studio:post-review"]');await click('[data-do="finish:scan"]');await test('Sequence review remains in Postproduction',`return st().finish.scanKey!==null&&st().view==='post'`);await shot('post-review');
 await test('Review follows the same montage',`a.action('workspace:edit');a.action('studio:duplicate');a.action('workspace:post');return q('#nd-inspector').textContent.includes('Schnitt geändert')||st().finish.scanKey!==JSON.stringify(st().nle)`);
 await test('Project geometry shared with output',`a.action('studio:project-settings');return !!q('[data-sx="fps"]')`);await change('[data-sx="fps"]',30);await change('[data-sx="aspect"]','9:16');await click('[data-do="studio:modal-close"]');
 await test('Export reflects fps and aspect',`a.action('workspace:finish');return q('#nd-inspector').textContent.includes('30 fps')&&q('#nd-inspector').textContent.includes('608 × 1080')`);await shot('export');
 await test('Media content search exposes time segments',`a.fixture('Medien');a.action('studio:search-moments');const el=q('[data-media-search]');el.value='Straße';el.dispatchEvent(new Event('input',{bubbles:true}));return !!q('.studio-search-detail')`);
 await test('Independent panels',`a.action('workspace:edit');q('[data-panel="sidebar"]').click();return !st().sidebarVisible&&st().inspector`);
 await test('References have all native entity types',`a.fixture('References');a.action('ref:identities');return st().studio.entities.some(e=>e.type==='Ensembles')&&q('[data-do="studio:entity-filter-Props"]')`);await shot('references');
 await test('Take review needs all six passes',`a.fixture('Takes');a.action('studio:take-review');return q('[data-do="studio:take-review-save"]').disabled`);
 for(let i=0;i<6;i++)await click('[data-sx="review-'+i+'"]');await click('[data-do="studio:take-review-save"]');
 await test('Take review records exact revision',`return st().studio.takeReviews['0-1'].checks.length===6`);
 await test('Blocking preserves shot',`a.fixture('Shotplanung');a.action('studio:blockout');return st().mode==='blockout'&&q('[data-sx="blockoutTime"]')`);await shot('blocking');
 await test('Settings expose provider/model/pack management',`a.action('studio:settings');return r.querySelectorAll('.studio-settings-tabs button').length===6`);
 for(const page of ['agent','providers','models','packs','storage'])await test('Settings '+page,`a.action('studio:settings-${page}');return q('.dialog').textContent.length>80`);
 await test('Pack mismatch is explicit',`a.action('studio:pack-missing');return !st().studio.packAvailable&&q('[data-do="studio:pack-restore"]')`);
 await test('Recovery creates a distinct project',`a.action('studio:pack-recovery');return st().name.includes('Recovery')&&st().studio.packAvailable`);
 const layouts=[];
 for(const width of [1440,1024,736,500,320]){await call('Emulation.setDeviceMetricsOverride',{width,height:1400,deviceScaleFactor:1,mobile:false},session);for(const v of ['Medien','Storyboard','Schnitt','Postproduction','Export']){await run(`a.fixture('${v}');`);await sleep(30);const x=await run(`const c=q('#nd-canvas');return {width:${width},view:'${v}',overflow:r.scrollWidth-r.clientWidth,canvasOverflow:c.scrollWidth-c.clientWidth,height:r.getBoundingClientRect().height}`);layouts.push(x);if(width===1024)await shot(v.toLowerCase());}}
 await writeFile(path.join(here,'review/studio-workspace-checks.json'),JSON.stringify({results,layouts},null,2));console.log(JSON.stringify({passed:results.filter(x=>x.pass).length,failed:results.filter(x=>!x.pass),layoutFailures:layouts.filter(x=>x.overflow>1||x.canvasOverflow>1)}));
} finally {clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
