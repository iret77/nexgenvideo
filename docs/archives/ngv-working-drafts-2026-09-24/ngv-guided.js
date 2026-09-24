function guidedInteraction(){
state.agent=true;
const music=state.workflow==='Music Video';
root.style.setProperty('--ngvs-accent',music?'#df9bc7':'#a9bdcf');
root.style.setProperty('--ngvs-select',music?'#df9bc717':'#a9bdcf17');
$('.s-pack').textContent=music?'Music Video · active format pack':'NexGenVideo · core workflow';
$('.s-agent-head strong').textContent='Interaction';
$('.s-agent-toggle').hidden=true;
$('[data-close-agent]').hidden=true;
$('.s-assistant-tabs').hidden=true;
$('.s-agent-context .s-meta').textContent='ACTIVE PRODUCTION STEP';
$('.s-scope-chip').textContent=phases[Math.min(state.current,phases.length-1)][1];
$('.s-conversation').hidden=true;
$('.s-agent-composer').hidden=true;
const currentID=phases[Math.min(state.current,phases.length-1)][0];
if(state.current!==phaseIndex('shotlist')){
$('.s-assistant-review').hidden=true;$('.s-assistant-job').hidden=false;
$('.s-assistant-job').innerHTML='<h3>'+phases[Math.min(state.current,phases.length-1)][1]+'</h3><p>'+ (state.current>phaseIndex('shotlist')?'Shot List approved. Continue with continuity and readiness checks.':'This phase has been reopened. Its downstream approvals need to be established again.')+'</p><button class="s-secondary" data-open="'+currentID+'">Open active artifact</button><p class="s-local-note">Execution of this phase is outside this mockup. No automatic approval.</p>';
}else if(state.ready){
$('.s-assistant-review').hidden=true;$('.s-assistant-job').hidden=false;
$('.s-assistant-job').innerHTML='<span class="s-tag s-ok">Ready for your decision</span><h3>Approve Shot List</h3><p>Timing and references checked. Your creative review is complete.</p><dl class="s-run-contract"><dt>Version</dt><dd>Draft v'+animaticPlan.revision+'</dd><dt>Next</dt><dd>Sanity Check</dd></dl><button class="s-primary" data-approve>Approve Shot List</button><button class="s-secondary" data-return-review>Review again</button>';
}else{
state.assistantTab=job.review==='ready'?'review':'task';
$('.s-assistant-job').hidden=state.assistantTab!=='task';$('.s-assistant-review').hidden=state.assistantTab!=='review';
}
$$('[data-open-task],[data-open-review]').forEach(b=>b.hidden=true);
const past=idx()>=0&&idx()<state.current;
$('.s-agent-context').setAttribute('aria-label','One active step for this project');
if(past){const box=document.createElement('div');box.className='s-run-summary';box.textContent='Viewing approved '+title()+'. The active step remains '+phases[Math.min(state.current,phases.length-1)][1]+'.';$('.s-assistant-job').prepend(box);}
$$('[data-discuss]').forEach(b=>{b.textContent='Review this step';});
$('.s-agent-status').textContent=job.status==='running'?'Checking Shot List · simulated':'One active step · interactive concept';
}
root.addEventListener('click',e=>{const b=e.target.closest('button');if(!b||b.disabled)return;if(b.hasAttribute('data-return-review')){state.ready=false;job.review='ready';render();}if(b.hasAttribute('data-discuss')){state.assistantTab=job.review==='ready'?'review':'task';render();}});
