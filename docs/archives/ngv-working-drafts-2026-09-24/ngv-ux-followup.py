from pathlib import Path
p=Path('docs/ui')
def rep(s,a,b):
 assert a in s,a[:100]
 return s.replace(a,b)
f=p/'build-desktop-production-workbench.py';s=f.read_text();s=rep(s,"css = compact(css, 'css')", "css = compact('#ngv-desk{' + css.replace('#ngv-desk', '&') + '}', 'css')");f.write_text(s)
f=p/'desktop-production-workbench.studio.js';s=f.read_text()
s=rep(s,"c.name??=S.shots[c.shot]?.id+' · Take '+c.take;", "c.name??=S.shots[c.shot]?.id+' · Take '+c.take;if(c.shot!==undefined&&c.take)c.asset??='take-'+c.shot+'-'+c.take;")
s=rep(s,"id:'track-song',name:", "id:'track-song',asset:S.trackMediaId||'track',name:")
s=rep(s,";aspect-ratio:${S.studio.aspect.replace(':','/')}", ";--picture-aspect:${aspect[0]/aspect[1]};aspect-ratio:${S.studio.aspect.replace(':','')}") if False else s
s=rep(s,";aspect-ratio:${S.studio.aspect.replace(':','/')};", ";--picture-aspect:${aspect[0]/aspect[1]};aspect-ratio:${S.studio.aspect.replace(':','/')};")
s=rep(s,"+SX('asset-offline',a.offline?'Als verfügbar markieren':'Offline-Fall simulieren',{cls:'control'})", "")
s=rep(s,"if(command==='asset-generate'){S.modal='gen-form';normalizeGeneration();S.generation.prompt=a?.generation?.prompt||'';dialog();return;}", "if(command==='asset-generate'){if(!a?.generation)return;const g=a.generation;S.generation={...generationDefault(),type:a.type,provider:g.provider,model:g.model,prompt:g.prompt,reference:g.reference||'',aspect:g.aspect||'16:9',duration:a.duration||5,folder:a.folder};normalizeGeneration();S.modal='gen-form';dialog();return;}")
f.write_text(s)
f=p/'desktop-production-workbench.studio.css';s=f.read_text();s+='''
#ngv-desk .studio-viewer{container-type:size}
#ngv-desk .studio-viewer>div{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:0}
#ngv-desk .studio-viewer .studio-picture{width:min(100%,calc((100cqh - 28px)*var(--picture-aspect)));max-height:calc(100cqh - 28px);flex:none}
#ngv-desk .studio-viewer small{flex:none}
''';f.write_text(s)
f=p/'desktop-production-workbench.media.js';s=f.read_text();s=rep(s,"origin:'Zugewiesener Projekttrack',folder:'sound'", "origin:'Zugewiesener Projekttrack',folder:'sound',transcript:S.lyrics?[{in:16,out:20,text:'A little wheel beneath the dust'},{in:48,out:52,text:'Turn it once and let it go'}]:[]");f.write_text(s)
