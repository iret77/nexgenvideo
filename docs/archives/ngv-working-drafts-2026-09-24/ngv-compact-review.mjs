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
 await call('Browser.getVersion');
 const {targetId}=await call('Target.createTarget',{url:pathToFileURL(path.join(here,'desktop-production-workbench.html')).href+'?view=Storyboard'});
 session=(await call('Target.attachToTarget',{targetId,flatten:true})).sessionId;
 for(let i=0;i<40;i++){if(await evalJS('!!document.getElementById("ngv-desk")?.ngvTest'))break;await sleep(100);}
 await call('Page.bringToFront',{},session);
 const results=[];
 async function check(name,expression){const pass=await evalJS(expression);results.push({name,pass:!!pass});if(!pass){console.log(await evalJS('JSON.stringify({active:document.activeElement?.outerHTML,focused:document.hasFocus(),state:document.getElementById("ngv-desk").ngvTest.state()})'));throw Error(name);}}
 const state='document.getElementById("ngv-desk").ngvTest.state()';
 async function key(selector,key,code,virtual){await evalJS(`document.querySelector('${selector}').focus()`);for(const type of ['keyDown','keyUp'])await call('Input.dispatchKeyEvent',{type,key,code,windowsVirtualKeyCode:virtual,...(type==='keyDown'?{text:key==='Enter'?'\r':key}: {})},session);}
 await check('Supplied panel icons render',`document.querySelectorAll('.panel-toggle svg').length===2`);
 await evalJS(`document.getElementById('ngv-desk').ngvTest.action('mode:animatic')`);
 await key('[data-panel=sidebar]','Enter','Enter',13);
 await check('Enter toggles only left panel',`!${state}.sidebarVisible&&${state}.inspector&&!${state}.playing`);
 await key('[data-panel=inspector]',' ','Space',32);
 await check('Space toggles Inspector without starting Animatic',`!${state}.sidebarVisible&&!${state}.inspector&&!${state}.playing`);
 await key('[data-panel=sidebar]',' ','Space',32);
 await check('Hidden sidebar restores through same control',`${state}.sidebarVisible&&!${state}.inspector`);
 await key('[data-panel=inspector]','Enter','Enter',13);
 await check('Hidden Inspector restores through same control',`${state}.sidebarVisible&&${state}.inspector`);
 const layouts=[];
 for(const width of [1440,1024,736,500,320]){
  await call('Emulation.setDeviceMetricsOverride',{width,height:1600,deviceScaleFactor:1,mobile:false},session);
  for(const mode of ['Storyboard','Schnitt','Finish']){
   await evalJS(`(()=>{const a=document.getElementById('ngv-desk').ngvTest;a.fixture('${mode}');const s=a.state();s.name='Claude Mouse · The very long production title for a multi scene animated music video';a.restore(s)})()`);
   await sleep(50);
   const layout=await evalJS(`(()=>{const title=document.querySelector('#nd-title'),rect=el=>{const r=el.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height,right:r.right,bottom:r.bottom}};const buttons=[...title.querySelectorAll('button')].map(b=>({...rect(b),label:b.getAttribute('aria-label')||b.textContent}));return {width:${width},mode:'${mode}',header:rect(title),project:rect(title.querySelector('.project-title')),buttons,icons:title.querySelectorAll('.panel-toggle svg').length,overlap:buttons.some((a,i)=>buttons.slice(i+1).some(b=>a.x<b.right&&a.right>b.x&&a.y<b.bottom&&a.bottom>b.y)),outside:buttons.some(b=>b.x<title.getBoundingClientRect().x||b.right>title.getBoundingClientRect().right),overflow:title.scrollWidth-title.clientWidth};})()`);
   layouts.push(layout);
   if(layout.overlap||layout.outside||layout.overflow>1||layout.icons!==2||width>=736&&layout.header.h>44)throw Error('Titlebar layout '+JSON.stringify(layout));
   if(width===1024||width===320){const shot=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false},session);await writeFile('/tmp/ngv-chrome-'+mode+'-'+width+'.png',Buffer.from(shot.data,'base64'));}
  }
 }
 await writeFile(path.join(here,'review/compact-chrome-checks.json'),JSON.stringify({checks:results,layouts},null,2)+'\n');
 console.log(JSON.stringify({checks:results,layouts:layouts.length,headerHeights:layouts.filter(l=>l.mode==='Storyboard').map(l=>({width:l.width,height:l.header.h,projectWidth:l.project.w}))}));
}finally{clearTimeout(deadline);await call('Browser.close').catch(()=>{});chrome.kill();}
