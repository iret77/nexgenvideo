from pathlib import Path
paths=[Path('docs/ui/production-workbench.html'),Path('<local home>/.codex/visualizations/2026/09/12/01a0956c-ab36-7ed3-b838-cf38a6f4b3b7/nexgenvideo-production-clickdummy.html')]
for p in paths:
 s=p.read_text().replace("$('.context-inspector').insertAdjacentHTML('beforeend',group('Direction',xb('creative','Request a change',!can)+xb('decisions','Decisions and changes')));", "$('.heading')?.insertAdjacentHTML('beforeend',xb('creative','Request a change',!can)+xb('decisions','Decisions'));" )
 # Hide future artifacts instead of displaying fixture data under a future phase label.
 s=s.replace("const can=editable(p);", "if(state.work==='plan'&&statusOf(p)==='upcoming'&&['board','list','animatic','blocking','production'].includes(state.view)){$('main').innerHTML=heading(p,'Upcoming · not yet available')+'<div class=\"reading\"><p>Complete '+esc(state.phase)+' before starting this phase.</p>'+xb('current-phase','Open current step')+'</div>';$('.context-inspector').innerHTML='<p>Select an available artifact.</p>';}const can=editable(p);")
 # guard conditional heading on future view.
 s=s.replace("if(['board','review','list','blocking'].includes(state.view)&&state.work==='plan'&&['Storyboard','Shot preparation'].includes(p))", "if(['board','review','list','blocking'].includes(state.view)&&state.work==='plan'&&statusOf(p)!=='upcoming'&&['Storyboard','Shot preparation'].includes(p))")
 p.write_text(s)
p=Path('docs/ui/production-workbench.test.js');s=p.read_text().replace("click('[data-source-shot=\"1\"]');check('Reference links back to shot',q('#nf-duration').value==='2')", "click('[data-source-shot=\"2\"]');check('Reference links back to shot',q('#nf-duration').value==='5')");p.write_text(s)
