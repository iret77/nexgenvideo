from pathlib import Path
v=Path('<local home>/.codex/visualizations/2026/09/12/01a0956c-ab36-7ed3-b838-cf38a6f4b3b7')
prior=(v/'nexgenvideo-visual-workbench.html').read_text()
css=prior[:prior.index('<div id="ngv-film"')]
fragment=css+Path('/tmp/ngv-flow.css').read_text()+'<div id="ngv-film" aria-label="NexGenVideo artifact-driven production workflow"></div>'+Path('/tmp/ngv-flow.js').read_text()
(v/'nexgenvideo-production-stages.html').write_text(fragment)
Path('docs/ui/production-stages-workbench.html').write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>NexGenVideo production stages</title><style>body{margin:0;background:#18191b}</style></head><body>'+Path('/tmp/ngv-flow-spec.html').read_text()+fragment+'<script>if(location.search.includes("selftest")){const t=document.createElement("script");t.src="production-stages-workbench.test.js";document.body.append(t);}</script></body></html>')
print(len(fragment.encode()))
