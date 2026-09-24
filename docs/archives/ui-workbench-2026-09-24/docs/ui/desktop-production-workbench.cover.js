const coverFormats=[['1:1','Quadrat'],['16:9','Querformat'],['9:16','Hochformat']];
function ensureArtwork(){
 S.cover??={aspect:'1:1',subject:'Figur',reference:'',hint:'',variant:'clean',artist:'',title:'',provider:'Runway',model:'runway/gen4_image',selected:{},clean:{},kept:[],skipped:[]};
 S.finish.preview??={enabled:false,mode:'frame',time:0,asset:'',aspect:S.studio.aspect,intent:'',reference:'',provider:'Runway',model:'runway/gen4_image',bound:null};
 const models=artworkModels();for(const c of [S.cover,S.finish.preview])if(!models.some(m=>m.id===c.model&&m.provider===c.provider)){const m=models.find(m=>m.provider===c.provider)||models[0];c.provider=m?.provider||'';c.model=m?.id||'';}
}
const albumAllowed=()=>S.pack==='Music Video'&&S.studio.packAvailable&&order().slice(0,order().indexOf('takes')+1).every(p=>S.done[p]);
const artworkAssets=()=>assets().filter(a=>!a.offline&&['image','reference'].includes(a.type));
const artworkContext=()=>S.finishSection==='album'?'album':'preview';
const artworkForm=()=>artworkContext()==='album'?S.cover:S.finish.preview;
const artworkModels=()=>usableGenerationModels().filter(m=>m.type==='image');
const artworkResults=kind=>artworkAssets().filter(a=>a.generation?.cover?.kind===kind&&(kind!=='album'||a.generation.aspect===S.cover.aspect));
function artworkReference(kind){return kind==='album'&&S.cover.variant==='text'?S.cover.clean[S.cover.aspect]:artworkForm().reference;}
function artworkModel(){const c=artworkForm();return artworkModels().find(m=>m.id===c.model&&m.provider===c.provider);}
function artworkModelControls(){const c=artworkForm(),models=artworkModels();return artworkSelect('Anbieter','provider',[...new Set(models.map(m=>m.provider))].map(x=>[x,x]))+artworkSelect('Modell','model',models.filter(m=>m.provider===c.provider).map(m=>[m.id,m.name]))+(!artworkModel()?'<small role="status">Kein ausführbares Demo-Bildmodell gewählt.</small>':'');}
function artworkSelect(label,key,items){const c=artworkForm();return `<label class="property"><span>${label}</span><select data-artwork="${key}" ${S.running?'disabled':''}>${items.map(([v,t])=>`<option value="${E(v)}" ${c[key]===v?'selected':''}>${E(t)}</option>`).join('')}</select></label>`;}
function artworkInput(label,key,rows=false){const c=artworkForm();return `<label class="artwork-input"><span>${label}</span>${rows?`<textarea data-artwork="${key}" rows="3" maxlength="500" ${S.running?'disabled':''}>${E(c[key])}</textarea>`:`<input data-artwork="${key}" value="${E(c[key])}" maxlength="80" ${S.running?'disabled':''}>`}</label>`;}
function artworkCanGenerate(){
 const kind=artworkContext(),c=artworkForm(),m=artworkModel(),ref=artworkReference(kind);
 return !S.running&&S.studio.packAvailable&&!!m&&(kind!=='album'||albumAllowed()&&!c.skipped.includes(c.aspect))&&(!ref||!!m.reference&&artworkAssets().some(a=>a.id===ref))&&(m.reference!=='required'||!!ref)&&(kind!=='album'||(c.variant==='text'?!!c.clean[c.aspect]&&!!c.artist.trim()&&!!c.title.trim():['Abstrakt','Eigene Idee'].includes(c.subject)?!!c.hint.trim():!!ref))&&(kind!=='preview'||!!ref||!!c.intent.trim());
}
function coverArt(a,aspect){
 if(!a)return '<div class="artwork-empty">Noch kein Bild ausgewählt</div>';
 const meta=a.generation?.cover,source=meta?.source||a,index=source.demoPic??source.shot;
 return `<div class="cover-art" style="--cover-aspect:${aspect.replace(':','/')}">${index!==undefined?pic(index,'reference'):'<div class="artwork-empty">Bildvorschau · Simulation</div>'}${meta?.variant==='text'?`<div class="cover-lettering"><span>${E(meta.artist)}</span><b>${E(meta.title)}</b></div>`:''}</div>`;
}
function albumCanvas(){
 const c=S.cover,list=artworkResults('album'),selected=list.find(a=>a.id===c.selected[c.aspect]),ref=artworkAssets().find(a=>a.id===artworkReference('album'));
 return `<section class="artwork-surface"><div class="artwork-stage">${coverArt(selected||ref,c.aspect)}</div><div class="artwork-caption">${c.skipped.includes(c.aspect)?'Format übersprungen':selected?(S.cover.kept.includes(selected.id)?'Behalten':'Entwurf')+' · '+E(selected.name):ref?'Referenz · noch kein Album-Cover':'Motiv und Referenz im Inspector wählen'}<small>${selected?'Layoutsimulation · kein tatsächliches KI-Rendering':c.aspect+' · '+(c.aspect==='1:1'?'Album-Cover':c.aspect==='16:9'?'Breite Artwork-Variante':'Hochkant-Artwork')}</small></div><div class="artwork-versions">${list.map(a=>B('artwork:select-'+a.id,coverArt(a,c.aspect)+`<span>${a.generation.cover.variant==='text'?'Mit Schrift':'Ohne Schrift'}${c.kept.includes(a.id)?' · ✓':''}</span>`,{attrs:`aria-pressed="${a.id===selected?.id}"`})).join('')}</div></section>`;
}
function albumInspector(){
 const c=S.cover,selected=artworkResults('album').find(a=>a.id===c.selected[c.aspect]),allowed=albumAllowed(),refs=artworkAssets();
 let body='<div class="inspector-header"><b>Album-Cover</b><small>Music Video · optional</small></div>';
 if(!allowed)body+='<p class="artwork-note" role="status">Erst die Produktion einschließlich Video-Takes freigeben. Der Videoexport bleibt unabhängig.</p>';
 body+=group('Motiv',artworkSelect('Art','subject',[['Figur','Figur'],['Ort','Ort'],['Abstrakt','Abstrakt'],['Eigene Idee','Eigene Idee']])+artworkSelect('Referenz','reference',[['','Ohne Referenz'],...refs.filter(a=>!a.generation?.cover).map(a=>[a.id,a.name])])+artworkInput(['Abstrakt','Eigene Idee'].includes(c.subject)?'Bildidee':'Bildidee · optional','hint',true));
 body+=group('Variante',artworkSelect('Ausführung','variant',[['clean','Ohne Schrift'],['text','Mit Schrift']])+(c.variant==='text'?(!c.clean[c.aspect]?'<small>Zuerst eine Variante ohne Schrift behalten.</small>':'')+artworkInput('Künstler','artist')+artworkInput('Titel','title')+'<small>Schrift wird mitgeneriert. Schreibweise am Ergebnis prüfen.</small>':''));
 body+=group('Generierung',artworkModelControls()+B('artwork:generate','Kosten prüfen…',{primary:true,cls:'control',disabled:!artworkCanGenerate()})+'<small>Modellliste, Textfähigkeit und Kosten sind simuliert.</small>');
 if(selected)body+=group('Bild prüfen',prop('Modell',selected.generation.model)+B('artwork:keep',c.kept.includes(selected.id)?'Behalten':'Bild behalten',{primary:!c.kept.includes(selected.id),cls:'control',disabled:S.running||!allowed||c.kept.includes(selected.id)})+B('artwork:reveal','In Medien zeigen',{cls:'control',disabled:S.running})+'<small>Motiv, Komposition und gegebenenfalls Schrift prüfen. Eine neue Variante ersetzt das Bild ohne Schrift nicht.</small>');
 return body+group('Format',B('artwork:skip',c.skipped.includes(c.aspect)?'Format wieder aufnehmen':'Format überspringen',{cls:'control',disabled:S.running}));
}
function previewSource(){const p=S.finish.preview;return p.mode==='frame'?studioVisualAt(Math.min(p.time,Math.max(0,nleTotal()-1/fps()))):artworkAssets().find(a=>a.id===p.asset);}
function previewSignature(){const p=S.finish.preview;return JSON.stringify({mode:p.mode,time:p.time,asset:p.asset,aspect:p.aspect,source:p.mode==='frame'?finishDigest():previewSource()});}
function previewCurrent(){const p=S.finish.preview;return !!p.bound&&p.bound.signature===previewSignature();}
function previewCanvas(){
 const p=S.finish.preview,a=previewSource();
 return `<section class="artwork-surface"><div class="artwork-stage">${p.mode==='frame'&&a?`<div class="preview-frame" style="--cover-aspect:${p.aspect.replace(':','/')};--source-aspect:${S.studio.aspect.replace(':','/')}">${studioPicture(a,p.time)}</div>`:coverArt(a,p.aspect)}</div><div class="artwork-caption">${p.mode==='frame'?tc(p.time)+' · '+(a?clipName(a):'Kein Bild an dieser Position'):a?E(a.name):'Bild auswählen oder generieren'}<small>${previewCurrent()?'Für die nächste Videoausgabe vorgemerkt':p.bound?'Auswahl geändert · erneut übernehmen':'Vorschaubild für die nächste Videoausgabe'} · Bildsimulation</small></div>${p.mode==='frame'?`<div class="preview-position"><label>Filmposition <span class="mono">${tc(p.time)}</span><input data-preview-time type="range" min="0" max="${Math.max(0,nleTotal()-1/fps())}" step="${1/fps()}" value="${p.time}" aria-label="Frame für Vorschaubild auswählen" ${S.running?'disabled':''}></label></div>`:''}${p.mode==='ai'?`<div class="artwork-versions">${artworkResults('preview').map(x=>B('artwork:preview-select-'+x.id,coverArt(x,p.aspect)+`<span>${E(x.name)}</span>`,{attrs:`aria-pressed="${x.id===p.asset}"`})).join('')}</div>`:''}</section>`;
}
function previewInspector(){
 const p=S.finish.preview,source=previewSource();let body='<div class="inspector-header"><b>Vorschaubild</b><small>Für diese Videoausgabe · optional</small></div>'+group('Bildformat',artworkSelect('Format','aspect',coverFormats.map(([v])=>[v,v]))+'<small>Separate PNG-Datei neben dem Video. Kein eingebranntes Bild im Film.</small>');
 if(p.mode==='media')body+=group('Projektmedien',artworkSelect('Bild','asset',[['','Bild auswählen'],...artworkAssets().map(a=>[a.id,a.name])]));
 if(p.mode==='ai')body+=group('Bildidee',artworkSelect('Referenz','reference',[['','Ohne Referenz'],...artworkAssets().filter(a=>!a.generation?.cover).map(a=>[a.id,a.name])])+artworkInput('Ergänzende Vorgabe','intent',true))+group('Generierung',artworkModelControls()+B('artwork:generate','Kosten prüfen…',{primary:true,cls:'control',disabled:!artworkCanGenerate()})+'<small>Demo-Modelle und Beispielkosten. Keine Anbieter verbunden.</small>');
 if(p.mode==='frame')body+=group('Filmframe',prop('Position',tc(p.time))+prop('Sequenz','Sequenz 01')+'<small>Enthält den aktuellen Bildlook und die Titel an dieser Position. Andere Bildformate beschneiden die Mitte.</small>');
 return body+group('Ausgabe',B('artwork:apply-preview',previewCurrent()?'Für Ausgabe gewählt':'Für Ausgabe übernehmen',{primary:true,cls:'control',disabled:S.running||!source||previewCurrent()})+`<label class="finish-check"><input type="checkbox" data-preview-enabled ${p.enabled?'checked':''} ${S.running?'disabled':''}><span>Vorschaubild beilegen</span></label>`+(p.enabled&&!previewCurrent()?'<small role="status">Bildauswahl zuerst übernehmen.</small>':'')+'<small>Jeder Export hält seine eigene Bildauswahl fest. Spätere Änderungen betreffen nur neue Ausgaben.</small>');
}
const artworkCanvasBase=finishCanvas,artworkInspectorBase=finishInspector,artworkToolsBase=finishTools;
finishCanvas=function(){ensureArtwork();return S.finishSection==='album'?albumCanvas():S.finishSection==='preview'?previewCanvas():artworkCanvasBase();};
finishInspector=function(){ensureArtwork();return S.finishSection==='album'?albumInspector():S.finishSection==='preview'?previewInspector():artworkInspectorBase();};
finishTools=function(){ensureArtwork();if(S.finishSection==='album')return '<strong>Album-Cover</strong><span class="grow"></span>'+coverFormats.map(([v,t])=>B('artwork:aspect-'+v,v,{attrs:`aria-label="${t}" aria-pressed="${S.cover.aspect===v}"`})).join('');if(S.finishSection==='preview')return '<strong>Vorschaubild</strong><span class="grow"></span>'+[['frame','Filmframe'],['media','Bild'],['ai','KI']].map(([v,t])=>B('artwork:mode-'+v,t,{attrs:`aria-pressed="${S.finish.preview.mode===v}"`})).join('');return artworkToolsBase();};
const artworkExportInspector=finishExportInspector;
finishExportInspector=function(){ensureArtwork();const p=S.finish.preview;return artworkExportInspector()+(S.finish.format==='video'?group('Vorschaubild',`<label class="finish-check"><input data-preview-enabled type="checkbox" ${p.enabled?'checked':''} ${S.running?'disabled':''}><span>Vorschaubild beilegen</span></label>`+prop('Bild',!p.enabled?'Ohne Vorschaubild':previewCurrent()?'Gewählt · '+p.aspect:'Auswahl erforderlich')+B('finish-section:preview','Bild auswählen…',{cls:'control',disabled:S.running})): '');};
const artworkReadyBase=finishReady;
finishReady=function(){ensureArtwork();return artworkReadyBase()&&(S.finish.format!=='video'||!S.finish.preview.enabled||previewCurrent());};
const artworkDialogBase=finishDialog;
finishDialog=function(){const result=artworkDialogBase();ensureArtwork();if(S.modal==='finish-export'&&S.finish.format==='video'&&S.finish.preview.enabled)result.body+='<p>Vorschaubild als zusätzliche PNG-Datei · '+E(S.finish.preview.aspect)+'</p>';return result;};
const artworkFinishAction=finishAction;
finishAction=function(command){ensureArtwork();if(['album','preview'].includes(S.finishSection)&&['play','start','prev','next','end'].includes(command))return;const before=S.finish.exports.length,p=S.finish.preview;artworkFinishAction(command);if(command==='start-export'&&S.finish.exports.length>before&&S.finish.format==='video'&&p.enabled){const item=S.finish.exports.at(-1);item.preview={...clone(p.bound),name:item.name.replace(/\.[^.]+$/,'')+'-preview.png'};persist();}};
const artworkHistoryInspector=finishHistoryInspector;
finishHistoryInspector=function(){const base=artworkHistoryInspector(),item=S.finish.exports.find(x=>x.id===S.finish.selectedExport);return base+(item?.preview?group('Vorschaubild',prop('Datei',item.preview.name)+prop('Format',item.preview.aspect)+prop('Quelle',item.preview.mode==='frame'?'Filmframe · '+tc(item.preview.time):item.preview.asset?.name||'Projektbild')+'<small>Bildauswahl dieses Auftrags · Dateiausgabe simuliert</small>'):'');};
const artworkGenerationBase=generationAction;
generationAction=function(command){if(command==='back'&&S.generation?.cover){generationQuote=null;S.modal=null;render();return;}if(command==='open'&&S.generation)delete S.generation.cover;if(command==='run'&&generationQuote?.cover){const q=generationQuote.cover;if(S.modal!=='gen-cost'||q.kind==='album'&&!albumAllowed()||q.context!==JSON.stringify(artworkForm())){generationQuote=null;S.modal=null;S.notice='Bildvorgaben geändert · Kosten erneut prüfen';render();return;}}artworkGenerationBase(command);};
const artworkActionBase=action;
action=function(command){
 if(!command.startsWith('artwork:')){if(command==='finish-section:album'&&S.pack!=='Music Video')return;artworkActionBase(command);return;}
 ensureArtwork();if(S.running)return;const cmd=command.slice(8),kind=artworkContext(),c=artworkForm();
 if(cmd.startsWith('aspect-')){c.aspect=cmd.slice(7);}
 else if(cmd.startsWith('mode-')){S.finish.preview.mode=cmd.slice(5);}
 else if(cmd.startsWith('preview-select-')){S.finish.preview.asset=cmd.slice(15);}
 else if(cmd.startsWith('select-')){c.selected[c.aspect]=cmd.slice(7);}
 else if(cmd==='keep'){if(!albumAllowed())return;const a=artworkResults('album').find(x=>x.id===c.selected[c.aspect]);if(a){c.kept=[...new Set([...c.kept,a.id])];if(a.generation.cover.variant==='clean')c.clean[c.aspect]=a.id;c.skipped=c.skipped.filter(x=>x!==c.aspect);}}
 else if(cmd==='skip'){c.skipped=c.skipped.includes(c.aspect)?c.skipped.filter(x=>x!==c.aspect):[...c.skipped,c.aspect];S.notice=c.skipped.includes(c.aspect)?'Format übersprungen':'Format wieder aufgenommen';}
 else if(cmd==='reveal'){const a=artworkResults('album').find(x=>x.id===c.selected[c.aspect]);if(a){S.mediaSelection=a.id;revealMedia();}return;}
 else if(cmd==='apply-preview'){const p=S.finish.preview,a=previewSource();if(a){p.bound={mode:p.mode,time:p.time,aspect:p.aspect,asset:clone(a),signature:previewSignature()};p.enabled=true;}}
 else if(cmd==='generate'){
  if(!artworkCanGenerate())return;const m=artworkModel(),ref=artworkReference(kind),source=artworkAssets().find(a=>a.id===ref),text=kind==='album'&&c.variant==='text';
  const prompt=kind==='album'?(text?`Create an integrated album artwork variant using the approved clean image. Exact artist: ${c.artist.trim()}. Exact title: ${c.title.trim()}. Preserve the motif and identity.`:`Create clean album artwork without any text. Subject: ${c.subject}. ${c.hint.trim()}`):`Create a preview image for a video export. ${c.intent.trim()}`;
  S.generation={type:'image',provider:m.provider,model:m.id,prompt:prompt+' Aspect '+c.aspect+'.',displayIntent:kind==='album'?(text?'Behaltenes Motiv mit Künstler „'+c.artist.trim()+'“ und Titel „'+c.title.trim()+'“':c.subject+' · '+(c.hint.trim()||'Motiv aus der gewählten Referenz')+' · ohne Schrift'):(c.intent.trim()||'Vorschaubild aus der gewählten Referenz'),name:kind==='album'?'Album-Cover '+c.aspect.replace(':','×')+(text?' · Künstler und Titel':' · Ohne Schrift'):'Vorschaubild '+c.aspect.replace(':','×'),duration:5,aspect:c.aspect,reference:ref||'',folder:'imports',cover:{kind,variant:text?'text':'clean',artist:text?c.artist.trim():'',title:text?c.title.trim():'',source:source?clone(source.generation?.cover?.source||source):null,context:JSON.stringify(c)}};
  normalizeGeneration();generationAction('review');return;
 }
 render();persist();
};
root.addEventListener('change',e=>{
 if(e.target.dataset.artwork){ensureArtwork();const c=artworkForm(),key=e.target.dataset.artwork;c[key]=e.target.value;if(key==='provider'){c.model=artworkModels().find(m=>m.provider===c.provider)?.id||'';}generationQuote=null;if(e.target.tagName==='SELECT'){render();$('[data-artwork="'+key+'"]')?.focus({preventScroll:true});}else{const b=$('[data-do="artwork:generate"]');if(b)b.disabled=!artworkCanGenerate();}persist();}
 if(e.target.matches('[data-preview-time]')){S.finish.preview.time=+e.target.value;render();persist();}
 if(e.target.matches('[data-preview-enabled]')){ensureArtwork();S.finish.preview.enabled=e.target.checked;render();persist();}
});
root.addEventListener('input',e=>{if(e.target.matches('[data-preview-time]')){stop();S.finish.preview.time=+e.target.value;const temp=document.createElement('div');temp.innerHTML=previewCanvas();for(const selector of ['.artwork-stage','.artwork-caption']){const target=$(selector);if(target)target.innerHTML=temp.querySelector(selector).innerHTML;}const time=$('.preview-position .mono');if(time)time.textContent=tc(S.finish.preview.time);inspector();paintIcons();persist();}if(e.target.matches('input[data-artwork],textarea[data-artwork]')){const c=artworkForm();c[e.target.dataset.artwork]=e.target.value;generationQuote=null;const b=$('[data-do="artwork:generate"]');if(b)b.disabled=!artworkCanGenerate();persist();}});
const artworkAssetImageBase=assetImage;
assetImage=function(a){return a?.generation?.cover&&!a.offline?coverArt(a,a.generation.aspect):artworkAssetImageBase(a);};
