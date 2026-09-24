const completePhaseRender=render;
render=function(){completePhaseRender();const p=contract.viewed;if(state.work==='plan'&&state.view==='phase'&&workspaceModels[p]&&editable(p)){
$$('main [data-x="phase-check"],main [data-x="doc-approve"],main [data-x="doc-save"],main [data-x="doc-reset"]').forEach(b=>b.remove());
$('footer').innerHTML='<button data-action="budget">€49.74 available</button><span class="grow"></span><span class="small muted" role="status">'+p+' · '+(demo.phaseDraft?'Editing draft':reviewed(p)?'Reviewed revision '+contract.versions[p]:'Review required')+'</span>'+(demo.phaseDraft?xb('doc-reset','Discard edits')+xb('doc-save','Save direction',false,true):xb('phase-check','Review artifact',reviewed(p)||contract.backend!=='ready')+xb('doc-approve','Approve '+p,!reviewed(p),true));
}
if(state.view==='intake')$$('main [data-x="intake-next"],main [data-x="lyrics-save"]').forEach(b=>$('footer').append(b));
};
