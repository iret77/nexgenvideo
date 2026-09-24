const results=[];
const root=document.getElementById('ngv-upstream');
const q=s=>root.querySelector(s);
const check=(name,pass)=>results.push({name,pass:!!pass});
const click=s=>q(s).click();
const input=(s,value)=>{q(s).value=value;q(s).dispatchEvent(new Event('input',{bubbles:true}));};
try{
check('Produce initial state',!q('.workspace').hidden&&q('.edit-workspace').hidden);
check('Produce fits viewport',document.documentElement.scrollWidth<=innerWidth);
click('[data-workspace="Edit"]');
check('Edit switching',q('.workspace').hidden&&!q('.edit-workspace').hidden);
check('Generated provenance',q('.inspector-body').textContent.includes('demo-generation-001'));
check('Edit fits viewport',document.documentElement.scrollWidth<=innerWidth);
click('[data-ai-edit]');check('Prepare disabled before description',q('[data-prepare]').disabled);
input('[data-edit-description]','Reduce contrast in the sky');check('Prepare enabled with description',!q('[data-prepare]').disabled);
click('[data-prepare]');check('Local proposal',q('.prepare-slot').textContent.includes('Edit proposal prepared'));
click('[data-asset="unavailable"]');check('Unavailable disabled action',q('[data-ai-edit]').disabled);check('Unavailable reason visible',q('.inspector-body').textContent.includes('Restore the source'));
click('[data-asset="imported"]');check('Imported not applicable',q('.inspector-body').textContent.includes('Not applicable'));
click('[data-asset="edited"]');click('[data-parent]');check('Parent navigation',q('.inspector-name').textContent==='street-at-dawn.png');
click('[data-inspect="clip"]');check('Reset absent at default',q('[data-reset]').hidden);
input('[data-field="scale"]','125');check('Reset after edit',!q('[data-reset]').hidden);
input('[data-field="opacity"]','101');check('Invalid opacity',!q('.field-error').hidden&&q('[data-field="opacity"]').getAttribute('aria-invalid')==='true');
click('[data-reset]');check('Reset actual value',q('[data-field="scale"]').value==='100'&&q('[data-reset]').hidden);
click('[data-timeline-mode="mixed"]');check('Mixed state',q('[data-field="scale"]').placeholder==='Mixed'&&q('.inspector-name').textContent==='2 clips selected');
for(const family of ['text','caption','speech','music']){click('[data-inspect="'+family+'"]');check('Inspector '+family,!!q('.ig'));}
click('[data-inspect="text"]');input('[data-field="text"]','Claude Mouse — The Comfort Engine');check('Text value reflected',q('.viewer-name').textContent==='Claude Mouse — The Comfort Engine');
click('[data-workspace="Produce"]');check('Return to Produce',!q('.workspace').hidden);
}catch(e){results.push({error:e.message,pass:false});}
const pre=document.createElement('pre');pre.id='mock-check-results';pre.textContent=JSON.stringify(results);document.body.append(pre);
