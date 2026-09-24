from pathlib import Path
p=Path('docs/ui/desktop-production-workbench.interaction.js');s=p.read_text().replace("${WI('take-overview','grid-2x2','Take-Übersicht')}","")
s=s.replace("issue?'Mit Abweichung auswählen':'Auswählen & weiter'", "issue?'Mit Abweichung auswählen':S.shots.some((_,i)=>i!==at()&&S.takes[i]?.length&&!S.chosen[i])?'Auswählen & weiter':'Auswählen'")
s=s.replace("const i=at(),t=S.studio.takeFocus;interactionBase.action(command);", "if(!isEdit()||!S.takeViewer||command==='wf:take-select'&&takeAssessment().issue&&!S.takeNote?.trim())return;const i=at(),t=S.studio.takeFocus;interactionBase.action(command);")
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.interaction.css');p.write_text(p.read_text()+'\n#ngv-desk .take-screen-strip>button{display:block}\n')
# Update prior test setups for the intentionally removed silent bulk-confirmation action.
p=Path('docs/ui/check-desktop-production-acceptance.mjs');s=p.read_text().replace("a.action('clay:accept-all');", "for(const i of [0,4]){a.action('clay:output-'+i);a.action('clay:accept');}")
s=s.replace("q('.wf-order-details').innerText.includes('Demo-Route')&&q('.wf-order-details').innerText.includes('Startbild')", "q('[data-production-model]').value.includes('Runway')&&q('.wf-order-details').innerText.includes('Shot-Anker')")
s=s.replace("const out=", "const out=")
# Keep historical evidence immutable.
s=s.replace('review/acceptance-2026-09-20','review/refinement-2026-09-20/regression')
p.write_text(s)
