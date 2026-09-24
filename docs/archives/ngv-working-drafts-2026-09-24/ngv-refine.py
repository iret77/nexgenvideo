from pathlib import Path
base=Path('docs/ui')
def edit(file,old,new):
 p=base/('desktop-production-workbench.'+file);s=p.read_text();assert old in s, (file,old[:100]);p.write_text(s.replace(old,new))
edit('clay.js',"CB('accept-all','Aktuelle Vorlagen sichten'", "CB('review-start','Vorlagen prüfen'")
edit('clay.js',"if(cmd==='inspect'){", "if(cmd==='review-start'){const next=clayIncluded().find(s=>clayOutputValid(s.id)&&!c.outputs[s.id].accepted);if(next){S.selected=[S.shots.indexOf(next)];c.outputFrame='start';c.reviewing=true;}render();return;}\n if(cmd==='inspect'){")
edit('clay.js',"else if(cmd==='accept-all'&&S.view==='blocking'){checkpoint();for(const s of clayIncluded())if(clayOutputValid(s.id))c.outputs[s.id].accepted=true;}", "else if(cmd==='accept-all'&&S.view==='blocking'){return;}")
edit('clay.js',"checkpoint();c.outputs[shot().id].accepted=true;}", "checkpoint();c.outputs[shot().id].accepted=true;const next=clayIncluded().find(s=>clayOutputValid(s.id)&&!c.outputs[s.id].accepted);if(c.reviewing&&next){S.selected=[S.shots.indexOf(next)];c.outputFrame='start';}}")
edit('clay.js',"c.view='outputs';}\n else if(cmd==='accept-all'", "c.view='outputs';c.reviewing=false;}\n else if(cmd==='accept-all'")
edit('media.js',"if(clearSelection)S.mediaMarked=[];", "if(clearSelection){S.mediaMarked=[];S.mediaSelection=null;S.mediaPreview=false;}")
edit('media.js',"S.mediaFolder=id;if(parent", "S.mediaFolder=id;S.mediaMarked=[];S.mediaSelection=null;S.mediaPreview=false;if(parent")
edit('media.js',"S.mediaQuery=e.target.value;S.mediaMarked=[];", "S.mediaQuery=e.target.value;S.mediaMarked=[];S.mediaSelection=null;S.mediaPreview=false;")
edit('media.js',"function normalizeMediaSelection(){const ids=new Set(assets().map(a=>a.id));", "function normalizeMediaSelection(){const ids=new Set((workspace()==='media'?poolItems():assets()).map(a=>a.id));")
edit('media.js',"if(S.mediaSelection&&!ids.has(S.mediaSelection)){", "if(S.mediaSelection&&(!ids.has(S.mediaSelection)||workspace()==='media'&&!S.mediaMarked.includes(S.mediaSelection))){")
edit('media.js',"mediaTool('studio:index','sliders-horizontal',S.studio.index?'Suchindex verwalten · bereit':'Suchindex verwalten · pausiert',S.running)", "mediaTool('studio:index','search',S.studio.index?'Inhaltssuche · bereit':'Inhaltssuche · pausiert',S.running)")
edit('media.js',"${poolItems().length} Medien", "${poolItems().length} ${poolItems().length===1?'Medium':'Medien'}")
edit('studio.js',"a.generation.reference||'Keine'", "assets().find(x=>x.id===a.generation.reference)?.name||'Keine'")
edit('studio.js',"poolItems().length+' Medien'", "poolItems().length+(poolItems().length===1?' Medium':' Medien')")
edit('studio.js',"if(S.nle.selectedTitle!==null||!c&&(S.nle.tab==='titles'||S.studio.post==='titles'))", "if(scope==='titles'||S.view==='edit'&&S.nle.selectedTitle!==null)")
edit('studio.js',"if(!c)return '<div class=\"inspector-header\"><b>Clip auswählen</b><small>Medien aus dem Quellenbrowser einsetzen.</small></div>';", "if(scope==='captions')return '<div class=\"inspector-header\"><b>Untertitel</b><small>Sequenz 01</small></div>'+studioCaptions();if(!c)return '<div class=\"inspector-header\"><b>'+({color:'Farbe',audio:'Ton',ai:'KI-Bearbeitung'}[scope]||'Clip')+'</b><small>'+(S.nle.selectedTitle!==null?'Titel ausgewählt · Videoclip in der Timeline auswählen.':'Clip in der Timeline auswählen.')+'</small></div>';" )
# Keep explicit object selection. A tool switch must never silently choose and edit a different clip.
edit('studio.js',"S.studio.post='audio';}else if(n.tab==='audio')n.tab='video';", "S.studio.post='audio';}else{if(n.tab==='audio')n.tab='video';if(S.view==='post'&&['titles','audio'].includes(S.studio.post))S.studio.post='color';}")
# Reset persistent dividers after jobs; allow reading without allowing writes.
edit('studio.js',"if(S.running)$$('button,input,select,textarea').forEach", "$$('[data-resize],[data-nle-height]').forEach(el=>el.disabled=false);if(S.running)$$('button,input,select,textarea').forEach")
edit('studio.js',"if(!el.dataset.panel&&!/^(background:", "if(!el.dataset.panel&&!el.dataset.resize&&!el.dataset.nleHeight&&!el.hasAttribute('data-open')&&!el.hasAttribute('data-shot')&&!el.hasAttribute('data-section')&&!/^(open:|mode:|ref:|segment:|moment:|sidebar:|wf:(audio-|refs-|compare-)|clay:(view-|shot-|output-|frame-|object-|endpoint-|inspect|plan|sketch)|background:")
# User-facing artwork intent, with compiler prompt remaining an internal implementation detail.
edit('cover.js',"name:kind==='album'?'Album-Cover '", "displayIntent:kind==='album'?(text?'Behaltenes Motiv mit Künstler „'+c.artist.trim()+'“ und Titel „'+c.title.trim()+'“':c.subject+' · '+(c.hint.trim()||'Motiv aus der gewählten Referenz')+' · ohne Schrift'):(c.intent.trim()||'Vorschaubild aus der gewählten Referenz'),name:kind==='album'?'Album-Cover '")
edit('generate.js',"E(q.prompt)", "E(q.displayIntent||q.prompt)")
edit('media.js',"E(a.generation.prompt)", "E(a.generation.displayIntent||a.generation.prompt)")
# Editing moves into the primary work area; no new scene imagery before story.
edit('js',"", "") if False else None
p=base/'desktop-production-workbench.js';s=p.read_text();start=s.index('function designView()');end=s.index('\nfunction docView',start)
s=s[:start]+'''function designView(){return `<div class="document design-editor"><div class="eyebrow">GESTALTUNG</div><div class="document-heading">Bildsprache festlegen</div>${selectField('Bildsprache','style',S.design.style,['Grafische Animation','Realfilm','Stop Motion','Dokumentarisch'])}${selectField('Farbwelt','palette',S.design.palette,['Warm / staubig','Kühl / reduziert','Natürlich','Schwarzweiß'])}${selectField('Bewegung','motion',S.design.motion,['Ruhig, motiviert','Dynamisch','Statisch'])}<div class="design-palette" aria-hidden="true" data-palette="${E(S.design.palette)}"><i></i><i></i><i></i><i></i><i></i></div><p class="meta">Stilregeln für Sketches und Renderings. Szenen entstehen im Treatment und Skript.</p></div>`;}''' +s[end:]
s=s.replace("if(p==='design')body=group('Bildsprache',selectField", "if(p==='design')body=group('Bildsprache',selectField") # Inspector replaced in workflow below.
s=s.replace("if(type==='identity'){S.identities=true;S.refMode='identities';}","if(type==='identity'){S.identities=true;if(S.view==='refs')S.refMode='identities';}")
s=s.replace("S.notice='Auftrag abgeschlossen · Ergebnis sichten';", "S.notice='';")
p.write_text(s)
