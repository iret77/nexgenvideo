from pathlib import Path
import re
paths=[Path('docs/ui/production-stages-workbench.html'),Path('<local home>/.codex/visualizations/2026/09/12/01a0956c-ab36-7ed3-b838-cf38a6f4b3b7/nexgenvideo-production-stages.html')]
for p in paths:
 s=p.read_text()
 def style(m):
  c=m[0]
  c=c.replace('border-top:3px solid var(--ng-accent)','border-top:1px solid var(--ng-line)')
  c=c.replace('border-color:var(--ng-accent)','border-color:var(--ng-line)')
  c=c.replace('outline:2px solid var(--ng-accent)','outline:2px solid var(--ng-text)')
  c=c.replace('border-bottom:2px solid var(--ng-accent)','border-bottom:2px solid var(--ng-text)')
  c=c.replace('border-left:3px solid var(--ng-accent)','border-left:1px solid transparent')
  c=c.replace('border-left:4px solid var(--ng-accent)','border:0;background:color-mix(in srgb,var(--ng-accent) 28%,var(--ng-panel));border-radius:4px;padding:3px 9px')
  c=c.replace('border-left:3px solid var(--ng-warn)','border-left:1px solid var(--ng-line)')
  c=re.sub(r'box-shadow:inset (?:0 -2px|3px 0) var\(--ng-accent\)','box-shadow:none',c)
  c=re.sub(r'background:color-mix\(in srgb,var\(--ng-accent\) (?:15|18|25|35|43)%,[^)]+\)','#TEMP#',c) if False else c
  for a in ['color-mix(in srgb,var(--ng-accent) 25%,var(--ng-panel))',"color-mix(in srgb,var(--ng-accent) 15%,#1d1e21)",'color-mix(in srgb,var(--ng-accent) 35%,#303136)','color-mix(in srgb,var(--ng-accent) 43%,#2c2d31)','color-mix(in srgb,var(--ng-accent) 18%,var(--ng-bg))']:
   c=c.replace(a,'#393a40')
  c=c.replace('width:2px;background:var(--ng-accent);pointer-events:none','width:2px;background:var(--ng-text);pointer-events:none')
  return c
 s=re.sub(r'<style>[\s\S]*?</style>',style,s)
 if p.name=='production-stages-workbench.html':
  marker='<h2>Existing NGV versus proposed changes</h2>'
  s=s.replace(marker,'<h2>Compatibility audit · 2026-09-17</h2><p>Local and remote main verified at 8bd8fbde. See <a href="review/code-compatibility-2026-09-17.md">source and upstream compatibility matrix</a>. Existing story chronology, causality bindings, state ladders, renderability checks and exact frame audit acceptance are reuse foundations. Script phase, import adoption and reordered planning/reference ownership require explicit contract work. The Pre-Render Review from #533 remains to be worked out in the clickdummy; no native capability or completed implementation is implied.</p><p>No colored decorative element borders. Use neutral selection surfaces and contrasting keyboard focus. Pack identity remains a filled label; primary actions and meaningful data marks may use the pack accent. Native metrics must map to AppTheme and retain 32/28 pt controls.</p>'+marker)
 p.write_text(s)
