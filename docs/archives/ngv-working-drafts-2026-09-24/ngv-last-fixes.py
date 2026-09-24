from pathlib import Path
p=Path('docs/ui')
f=p/'desktop-production-workbench.studio.js';s=f.read_text().replace("filter(([k])=>c.type!=='audio'||k==='gain')", "filter(([k])=>(S.view==='post'?S.studio.post:S.nle.tab)==='audio'?k==='gain':k!=='gain')")
s=s.replace("if(command==='grade-reset'){checkpoint();if(gradeFields[t.postTab])", "if(command==='grade-reset'){checkpoint();for(const c of selectedClips().filter(c=>c.type!=='audio')){if(gradeFields[t.postTab])")
s=s.replace("else c.fx={};refresh();return;", "else if(t.postTab==='curves')Object.keys(c.fx).filter(k=>k.startsWith('curve')).forEach(k=>delete c.fx[k]);else if(t.postTab==='wheels')Object.keys(c.fx).filter(k=>k.startsWith('wheel')).forEach(k=>delete c.fx[k]);else if(t.postTab==='lut'){delete c.fx.lut;delete c.fx.lutAmount;}}refresh();return;")
s=s.replace("c.fx.lut=t.lutFile||'Film-Look.cube';c.fx.lutAmount=100;", "for(const x of selectedClips().filter(x=>x.type!=='audio')){x.fx.lut=t.lutFile||'Film-Look.cube';x.fx.lutAmount=100;}")
p.joinpath(f.name).write_text(s)
f=p/'desktop-production-workbench.css';f.write_text(f.read_text().replace('#ngv-desk .overlay-backdrop{','#ngv-desk .overlay-backdrop,#ngv-desk .dialog-shade{'))
f=p/'check-desktop-production-guards.mjs';s=f.read_text().replace("a.action('studio:duplicate');return q('[data-do=\"studio:task-accept\"]').disabled", "a.action('workspace:edit');a.action('studio:duplicate');a.action('workspace:post');return q('[data-do=\"studio:task-accept\"]').disabled");f.write_text(s)
