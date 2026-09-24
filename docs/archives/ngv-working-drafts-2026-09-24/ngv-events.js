root.addEventListener('click',e=>{const b=e.target.closest('button');if(!b||b.disabled)return;
if(b.dataset.assistantTab){state.assistantTab=b.dataset.assistantTab;render();}
if(b.hasAttribute('data-show-animatic')){navigate('storyboard');state.mode='animatic';render();}
if(b.dataset.anim){const rows=planRows(),r=activeShot();if(b.dataset.anim==='play')startAnimatic();else seekAnimatic(b.dataset.anim==='start'?0:b.dataset.anim==='next'?rows[Math.min(rows.length-1,r.index+1)].start:rows[Math.max(0,r.index-1)].start);}
if(b.hasAttribute('data-cut'))seekAnimatic(planRows()[Number(b.dataset.cut)].start);
if(b.hasAttribute('data-apply-timing')){const v=$$('[data-duration]').map(x=>Number(x.value));if(v.some(x=>!Number.isFinite(x)||x<.5||x>30||x*2%1))$('.s-validation').textContent='Enter durations from 0.5 to 30 seconds in 0.5-second steps.';else applyTiming(v);}
if(b.hasAttribute('data-run-task'))runTask();
if(b.hasAttribute('data-stop-run')){clearTimeout(runTimer);job.status='stopped';render();}
if(b.hasAttribute('data-open-review')){state.assistantTab='review';render();}
if(b.hasAttribute('data-open-task')){state.assistantTab='task';render();}
if(b.hasAttribute('data-review-cut')){navigate('storyboard');state.mode='animatic';render();seekAnimatic(planRows()[2].start);}
if(b.hasAttribute('data-propose-hold')){job.proposed=true;render();}
if(b.hasAttribute('data-cancel-hold')){job.proposed=false;render();}
if(b.hasAttribute('data-apply-hold')&&state.current===phaseIndex('shotlist')){const v=animaticPlan.shots.map(s=>s.frames/24);v[2]++;applyTiming(v);state.assistantTab='task';render();}
if(b.hasAttribute('data-dismiss-finding')){job.decision='kept';job.proposed=false;render();}
if(b.hasAttribute('data-ready-decision')&&job.decision!=='open'&&state.current===phaseIndex('shotlist')){state.ready=true;navigate('shotlist');}
if(b.hasAttribute('data-import-preview')){state.importPreview=true;render();}
if(b.hasAttribute('data-stage-import')){const n=$$('[data-import-item]:checked').length;$('.s-import-status').textContent=n?n+' material groups staged in this demo. '+($('[data-import-choice]').value==='pending'?'Timing conflict remains unresolved.':'Timing choice recorded as a proposal. No approved artifact changed.'):'Select material to stage.';}
});
root.addEventListener('input',e=>{if(e.target.matches('.s-scrub'))seekAnimatic(Number(e.target.value));});
root.addEventListener('change',e=>{if(e.target.hasAttribute('data-speed')){pauseAnimatic();animSpeed=Number(e.target.value);paintAnimatic();}});
document.addEventListener('visibilitychange',()=>{if(document.hidden){pauseAnimatic();paintAnimatic();}});
