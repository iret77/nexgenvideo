from pathlib import Path
import base64
v=Path('<local home>/.codex/visualizations/2026/09/12/01a0956c-ab36-7ed3-b838-cf38a6f4b3b7')
a='<style>#ngv-film{--ng-prod:url(data:image/jpeg;base64,'+base64.b64encode((v/'storyboard-concept.jpg').read_bytes()).decode()+');--ng-sketch:url(data:image/jpeg;base64,'+base64.b64encode((v/'storyboard-sketches.jpg').read_bytes()).decode()+');}</style>\n'
fragment=Path('/tmp/ngv-v2.css').read_text()+a+'<div id="ngv-film" aria-label="NexGenVideo visual production workbench"></div>\n'+Path('/tmp/ngv-v2.js').read_text()
(v/'nexgenvideo-visual-workbench.html').write_text(fragment)
Path('docs/ui/visual-production-workbench.html').write_text('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>NexGenVideo visual workbench</title><style>body{margin:0;background:#18191b}</style></head><body>'+Path('/tmp/ngv-v2-spec.html').read_text()+fragment+'<script>if(location.search.includes("selftest")){const s=document.createElement("script");s.src="visual-production-workbench.test.js";document.body.append(s);}</script></body></html>')
