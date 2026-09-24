from pathlib import Path
s=Path('/tmp/ngv-fix.js').read_text()
s=s.replace("root.addEventListener('click',e=>", "root.addEventListener('click',e=>",1)
pos=s.index('const shots=');s=s[:pos]+"root.addEventListener('click',routeClick,true);\n"+s[pos:]
s=s.replace("function changed(){state.revision++;", "function changed(){invalidate(state.phase);state.revision++;")
s=s.replace("if(name==='Media review'){state.view='media';}render();", "if(name==='Media review'){state.view='media';}seedContract();render();")
s=s.replace("demo.job='complete';demo.takes=true;", "demo.job='complete';demo.takes=true;contract.takeBinding=contract.jobBinding;")
s=s.replace("render();if(globalThis.Tweak)",Path('/tmp/ngv-contract.js').read_text()+"\nrender();if(globalThis.Tweak)")
# Review-only fields are guarded by the same authoritative check as the buttons.
s=s.replace("const a=b.dataset.action,x=b.dataset.x;", "const a=b.dataset.action,x=b.dataset.x;if(['doc-edit','doc-reset'].includes(x)){e.stopImmediatePropagation();if(b.disabled||!editable(contract.viewed))return;demo.phaseDraft=x==='doc-edit';render();return;}")
for p in [Path('docs/ui/production-workbench.html'),Path('<local home>/.codex/visualizations/2026/09/12/01a0956c-ab36-7ed3-b838-cf38a6f4b3b7/nexgenvideo-production-clickdummy.html')]:
 text=p.read_text();a=text.index('<script>');b=text.index('</script>',a);p.write_text(text[:a]+'<script>\n'+s+text[b:])
print('Updated script',len(s))
