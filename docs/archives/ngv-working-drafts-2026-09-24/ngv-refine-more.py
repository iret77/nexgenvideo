from pathlib import Path
base=Path('docs/ui')
def edit(file,old,new):
 p=base/('desktop-production-workbench.'+file);s=p.read_text();assert old in s,(file,old[:90]);p.write_text(s.replace(old,new))
edit('workflow.js',"S.modal='studio-take-review';dialog();return;", "S.modal=null;S.takeViewer=true;render();return;")
edit('workflow.js',"S.modal!=='studio-take-review'", "!S.takeViewer")
edit('workflow.js',"S.takeNote=S.studio.takeReviews[at()+'-'+S.studio.takeFocus]?.note||'';dialog();return;", "S.takeNote=S.studio.takeReviews[at()+'-'+S.studio.takeFocus]?.note||'';render();return;")
edit('workflow.js',"S.notice=target.id+' korrigiert · Shotplanung erneut freigeben';", "S.correction={shotID:target.id,from:f.from,before:f.before,after:f.after};S.notice='';")
edit('workflow.js',"field('Ausgang','stateOut',shot().stateOut),false)", "field('Ausgang','stateOut',shot().stateOut),!!S.correction)")
edit('workflow.js',"'Auswahl sichten'", "'Auswahl bestätigen'")
edit('workflow.js',"${quote('anchor').ids.length} betroffene Shots", "${quote('anchor').ids.length} ${quote('anchor').ids.length===1?'betroffener Shot':'betroffene Shots'}")
# The batch engine uses the explicitly accepted, snapshotted quotation for costs and inputs.
edit('studio.js',"if(q.revision!==S.version||q.context!==finishDigest()||S.cost+(q.cost||0)>S.cap)return;if(!q.selected.length)return;q.targets", "if(q.revision!==S.version||q.context!==finishDigest()||S.cost+(q.cost||0)>S.cap||!productionQuoteValid(q))return;if(!q.selected.length)return;q.targets")
edit('studio.js',"q.context!==finishDigest()||S.cost+Math.max(0,q.targets.length-(q.completed||0))*.4>S.cap", "q.context!==finishDigest()||!productionQuoteValid(q)||S.cost+q.quote.rows.slice(q.completed||0).reduce((sum,r)=>sum+r.cost,0)>S.cap")
edit('studio.js',"q.revision!==S.version||S.cost+.4>S.cap", "q.revision!==S.version||!productionQuoteValid(q)||S.cost+(q.quote.rows.find(r=>r.i===i)?.cost||0)>S.cap")
edit('studio.js',"S.takes[i].push(nextTake(i));S.cost+=.4;}q.completed++", "const row=q.quote.rows.find(r=>r.i===i);S.takes[i].push(nextTake(i));S.cost+=row.cost;S.productionReceipts??={};S.productionReceipts[S.shots[i].id+'~'+S.takes[i].at(-1)]={model:q.quote.model,provider:q.quote.provider,duration:row.duration,cost:row.cost};}q.completed++")
# Start the separate interaction refinement layer after the established feature modules.
p=base/'desktop-production-workbench.js';s=p.read_text().replace('/*__WORKFLOW_JS__*/','/*__WORKFLOW_JS__*/\n/*__INTERACTION_JS__*/');p.write_text(s)
p=base/'build-desktop-production-workbench.py';s=p.read_text().replace("'clay', 'workflow']", "'clay', 'workflow', 'interaction']");s=s.replace("(root/'desktop-production-workbench.workflow.css').read_text()", "(root/'desktop-production-workbench.workflow.css').read_text() + (root/'desktop-production-workbench.interaction.css').read_text()");p.write_text(s)
