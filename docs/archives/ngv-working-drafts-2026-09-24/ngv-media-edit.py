from pathlib import Path
p=Path('docs/ui/desktop-production-workbench.js')
s=p.read_text()
a=s.index('const mediaTypes=');b=s.index('function browser()',a)
s=s[:a]+'/*__MEDIA_JS__*/\n'+s[b:]
s=s.replace("mediaImports:[],finishSection", "mediaImports:[],mediaFolder:'all',mediaFolders:[],mediaFolderNames:{},mediaLocations:{},mediaExpanded:['references'],mediaView:'list',mediaQuery:'',mediaSortDescending:false,mediaNextFolder:1,finishSection")
s=s.replace("if(phase==='edit'){S.mediaOpen=true;S.mediaFilter='video';}","if(phase==='edit'){S.mediaOpen=true;S.left=300;}")
s=s.replace("'mediaFilter','mediaSelection'", "'mediaFilter','mediaFolder','mediaExpanded','mediaView','mediaQuery','mediaSortDescending','mediaSelection'")
s=s.replace("if(verb==='nle')", "if(verb==='pool'){poolAction(param);return;}\n if(verb==='nle')")
s=s.replace("S.mediaFilter=e.target.value;browser();persist();return;", "S.mediaFilter=e.target.value;refreshPool();return;")
s=s.replace("if(verb==='sidebar'){S.mediaOpen=param==='media';browser();persist();return;}", "if(verb==='sidebar'){S.mediaOpen=param==='media';browser();paintIcons();persist();return;}")
s=s.replace("S.mediaFilter='sketch';S.mediaPreview=false", "S.mediaFilter='sketch';S.mediaFolder='all';S.mediaQuery='';S.mediaPreview=false")
s=s.replace("S.left=Math.max(130,Math.min(240,v))", "S.left=Math.max(166,Math.min(480,v))")
s=s.replace("S.left+'px'", "'min('+S.left+'px, 36%)'")
s=s.replace("'Medieninformation',prop('Herkunft',a.origin)","'Medieninformation',prop('Ordner',folderPath(a.folder).map(f=>f.name).join(' / '))+prop('Herkunft',a.origin)")
s=s.replace("a.type==='video'?'Schnitt / Quellclip':'Projekt-Audio'", "a.type==='video'?'Schnitt / Quellclip':a.type==='text'?(a.phase?labels[a.phase]:'Textmaterial'):'Projekt-Audio'")
s=s.replace("+'<small>Sichten verändert keine Shot-Zuweisung.</small>'", "+(a.phase?B('pool:document','In '+labels[a.phase]+' öffnen',{cls:'control'}):'')+B('pool:move','In Ordner verschieben…',{cls:'control',disabled:S.running})+'<small>Sichten verändert keine Shot-Zuweisung.</small>'")
s=s.replace("if(S.mediaPreview&&selectedAsset()){$('#nd-canvas').innerHTML=", "if(S.mediaPreview&&selectedAsset()?.type==='text'){$('#nd-canvas').innerHTML=mediaDocumentView(selectedAsset());return;}if(S.mediaPreview&&selectedAsset()){$('#nd-canvas').innerHTML=")
s=s.replace('<option value="audio">Claude-mouse.wav</option></select>', '<option value="audio">Claude-mouse.wav</option><option value="text">Lyrics-Entwurf.txt</option></select>')
s=s.replace("case'import-media-file':{const kind=$('#nd-media-kind').value;S.mediaImports.push({id:'import-'+S.mediaImports.length,name:kind==='audio'?'Claude-mouse.wav':'Street-take-01.mov',type:kind,origin:'Importierte Beispieldatei'});S.mediaOpen=true;S.mediaFilter=kind;", "case'import-media-file':{const kind=$('#nd-media-kind').value;checkpoint();S.mediaImports.push({id:'import-'+S.mediaImports.length,name:kind==='audio'?'Claude-mouse.wav':kind==='text'?'Lyrics-Entwurf.txt':'Street-take-01.mov',type:kind,content:kind==='text'?'[Verse]\\nA little wheel beneath the dust,\\nA quiet street, a spark of trust.\\n\\n[Chorus]\\nTurn it once and let it go,\\nWatch the sleeping city glow.':undefined,folder:S.mediaFolder==='all'?'imports':S.mediaFolder,origin:'Importierte Beispieldatei'});S.mediaOpen=true;S.mediaQuery='';S.mediaFilter=kind;")
needle=" if(modal==='sketch-example')"
pos=s.index(needle)
s=s[:pos]+''' if(modal==='pool-new'||modal==='pool-rename'){const folder=mediaFolders().find(f=>f.id===S.mediaFolder);title=modal==='pool-new'?'Ordner anlegen':'Ordner umbenennen';body=`<label for="nd-folder-name">Name</label><input id="nd-folder-name" maxlength="80" value="${modal==='pool-rename'?E(folder?.name):''}" placeholder="Ordnername"><small>${modal==='pool-new'?'In: '+E(folder?.name||'Projektmedien'):''}</small>`;actions=B('pool:save-folder',modal==='pool-new'?'Anlegen':'Umbenennen',{primary:true,disabled:modal==='pool-new'});}
 if(modal==='pool-move'){title='Medium verschieben';body=`<p>${E(selectedAsset()?.name)}</p><label for="nd-folder-target">Zielordner</label><select id="nd-folder-target">${mediaFolders().map(f=>`<option value="${f.id}" ${selectedAsset()?.folder===f.id?'selected':''}>${E(folderPath(f.id).map(p=>p.name).join(' / '))}</option>`).join('')}</select><p>Die Zuordnung zu Shots und Pipeline bleibt erhalten.</p>`;actions=B('pool:save-move','Verschieben',{primary:true});}
'''+s[pos:]
p.write_text(s)
p=Path('docs/ui/desktop-production-workbench.edit.js');s=p.read_text()
s=s.replace("if(S.mediaPreview&&!source)return", "if(S.mediaPreview&&a?.type==='text')return mediaDocumentView(a);\n if(S.mediaPreview&&!source)return")
s=s.replace("if(S.mediaPreview&&a)return", "if(S.mediaPreview&&a&&a.type!=='video')return mediaInspector();if(S.mediaPreview&&a)return")
s=s.replace("+B('sequence','Timeline zeigen',{cls:'control'})", "+B('pool:move','In Ordner verschieben…',{cls:'control',disabled:S.running})+B('sequence','Timeline zeigen',{cls:'control'})")
p.write_text(s)
p=Path('docs/ui/build-desktop-production-workbench.py');s=p.read_text().replace(".replace('/*__EDIT_JS__*/'", ".replace('/*__MEDIA_JS__*/', (root/'desktop-production-workbench.media.js').read_text()).replace('/*__EDIT_JS__*/'")
p.write_text(s)
