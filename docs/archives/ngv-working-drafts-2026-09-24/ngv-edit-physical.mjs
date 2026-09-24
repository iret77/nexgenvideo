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
try{
 await call('Browser.getVersion');const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Schnitt'});session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;await call('Page.bringToFront',{},session);
 for(let i=0;i<40;i++){if(await evalJS('!!document.getElementById("ngv-desk")?.ngvTest'))break;await sleep(100);}
 const results=[];const api='document.getElementById("ngv-desk").ngvTest',state=api+'.state()';
 async function check(name,expression){const pass=await evalJS(expression);results.push({name,pass:!!pass});if(!pass){console.log(await evalJS('JSON.stringify({focus:document.activeElement?.outerHTML,playing:document.getElementById("ngv-desk").ngvTest.state().playing,cursor:document.getElementById("ngv-desk").ngvTest.state().nle.cursor})'));throw Error(name);}}
 async function point(selector,x=.5,y=.5){return await evalJS(`(()=>{const r=document.querySelector('${selector}').getBoundingClientRect();return {x:r.left+r.width*${x},y:r.top+r.height*${y}}})()`);}
 async function mouse(type,p,extra={}){await call('Input.dispatchMouseEvent',{type,...p,...extra},session);}
 async function click(selector,x=.5){const p=await point(selector,x);await mouse('mousePressed',p,{button:'left',clickCount:1});await mouse('mouseReleased',p,{button:'left',clickCount:1});}
 async function key(key,code,virtual,modifiers=0){for(const type of ['keyDown','keyUp'])await call('Input.dispatchKeyEvent',{type,key,code,windowsVirtualKeyCode:virtual,modifiers,...(type==='keyDown'?{text:key==='Enter'?'\r':key}:{})},session);}
 await click('[data-nle-clip="clip-0"]',.6);await check('Physical timeline click seeks selected clip',`${state}.nle.selected==='clip-0'&&${state}.nle.cursor>1&&${state}.nle.cursor<3`);
 await key('k','KeyK',75,2);await check('Ctrl+K splits the selected clip at playhead',`${state}.nle.clips.length===7`);
 await click('[data-do=undo]');await check('Undo restores split through titlebar action',`${state}.nle.clips.length===6`);
 let p=await point('[data-clip-id="clip-0"][data-nle-trim=out]');await mouse('mousePressed',p,{button:'left',clickCount:1});await mouse('mouseMoved',{x:p.x-35,y:p.y},{button:'left',buttons:1});await mouse('mouseReleased',{x:p.x-35,y:p.y},{button:'left',clickCount:1});
 await check('Physical edge drag trims without moving next clip',`${state}.nle.clips[0].out<3&&${state}.nle.clips[1].start===3`);await click('[data-do=undo]');
 p=await point('[data-nle-height]');const h=await evalJS(`${state}.nle.height`);await mouse('mousePressed',p,{button:'left',clickCount:1});await mouse('mouseMoved',{x:p.x,y:p.y-60},{button:'left',buttons:1});await mouse('mouseReleased',{x:p.x,y:p.y-60},{button:'left',clickCount:1});await check('Horizontal divider resizes the whole timeline',`${state}.nle.height===${h+60}`);
 await click('[data-do="nle:play"]');await sleep(180);await key(' ','Space',32);await check('Playback retains focused play button for Space to pause',`!${state}.playing&&document.activeElement.dataset.do==='nle:play'`);
 const layouts=[];for(const width of [1440,1024,736,500,320]){await call('Emulation.setDeviceMetricsOverride',{width,height:1600,deviceScaleFactor:1,mobile:false},session);await evalJS(api+".fixture('Schnitt')");await sleep(80);const l=await evalJS(`(()=>{const r=document.querySelector('#ngv-desk'),p=document.querySelector('.nle-picture').getBoundingClientRect(),d=document.querySelector('#nd-edit-dock').getBoundingClientRect();return {width:${width},overflow:r.scrollWidth-r.clientWidth,ratio:p.width/p.height,timelineWidth:d.width,appWidth:r.clientWidth,mainHeight:document.querySelector('main').clientHeight,height:r.getBoundingClientRect().height}})()`);layouts.push(l);if(Math.abs(l.ratio-16/9)>.02||l.overflow>1||l.timelineWidth<l.appWidth-2)throw Error(JSON.stringify(l));if([1024,736,320].includes(width)){const im=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-editor-final-'+width+'.png',Buffer.from(im.data,'base64'));}}
 await writeFile(path.join(here,'review/edit-workbench-checks.json'),JSON.stringify({results,layouts},null,2)+'\n');console.log(JSON.stringify({results,layouts}));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
