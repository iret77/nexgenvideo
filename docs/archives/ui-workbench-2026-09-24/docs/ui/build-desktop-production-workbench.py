from pathlib import Path
import base64
import gzip
import json
import re
import os
import shutil
import subprocess
root = Path(__file__).resolve().parent
viz = Path(os.environ.get('NGV_MOCK_OUTPUT', '<local home>/.codex/visualizations/2026/09/12/01a0956c-ab36-7ed3-b838-cf38a6f4b3b7'))
viz.mkdir(parents=True, exist_ok=True)
minifier = os.environ.get('NGV_ESBUILD') or shutil.which('esbuild')
if not minifier:
    cached = sorted(Path('<local home>/.npm/_npx').glob('*/node_modules/@esbuild/linux-x64/bin/esbuild'))
    if cached:
        minifier = str(cached[0])
assert minifier, 'Set NGV_ESBUILD to an installed esbuild binary to package this static mockup.'
def compact(text, loader):
    result = subprocess.run([minifier, '--minify', '--charset=utf8', '--loader='+loader, '--target=es2022'], input=text, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    return result.stdout
css = (root/'desktop-production-workbench.css').read_text() + (root/'desktop-production-workbench.studio.css').read_text() + (root/'desktop-production-workbench.clay.css').read_text() + (root/'desktop-production-workbench.workflow.css').read_text() + (root/'desktop-production-workbench.interaction.css').read_text() + (root/'desktop-production-workbench.navigation.css').read_text()
def remove_overridden_declarations(source):
    rules = []
    def scan(start, end, context=()):
        while start < end:
            opening = source.find('{', start, end)
            if opening < 0:
                return
            selector = source[start:opening].strip()
            depth, closing = 1, opening + 1
            while closing < end and depth:
                depth += (source[closing] == '{') - (source[closing] == '}')
                closing += 1
            if selector.startswith('@'):
                scan(opening + 1, closing - 1, context + (selector,))
            else:
                rules.append((opening + 1, closing - 1, (context, selector)))
            start = closing
    scan(0, len(source))
    seen = {}
    for start, end, key in reversed(rules):
        properties = seen.setdefault(key, set())
        kept = []
        for declaration in reversed(source[start:end].split(';')):
            if ':' not in declaration:
                continue
            name, value = declaration.split(':', 1)
            identity = (name.strip(), '!important' in value)
            if identity not in properties:
                kept.append(declaration)
            properties.add(identity)
        source = source[:start] + ';'.join(reversed(kept)) + source[end:]
    return source
css = remove_overridden_declarations(css)
for size in [11, 12, 13, 17]:
    value = f'calc({size}px * var(--nd-ui-scale,1))'
    css = css.replace(value, f'var(--nd-f{size})') + f'#ngv-desk{{--nd-f{size}:{value}}}'
for token, name in [('__SKETCH__', 'storyboard-sketches.webp'), ('__REFERENCE__', 'storyboard-concept.webp'), ('__MOMENTS__', 'shot-1e-moments.webp')]:
    css = css.replace(token, 'data:image/webp;base64,' + base64.b64encode((root/'workbench-assets'/name).read_bytes()).decode())
css = compact('#ngv-desk{' + css.replace('#ngv-desk', '&') + '}', 'css')
js = (root/'desktop-production-workbench.js').read_text()
for module in ['media', 'generate', 'edit', 'finish', 'studio', 'background', 'cover', 'clay', 'workflow', 'interaction', 'navigation', 'context']:
    js = js.replace('/*__'+module.upper()+'_JS__*/', (root/('desktop-production-workbench.'+module+'.js')).read_text())
fragment_source = (root/'desktop-production-workbench.fragment.html').read_text()
token_source = css + fragment_source + js
tokens = sorted(set(re.findall(r'--[a-z][a-z0-9-]+', token_source)), key=len, reverse=True)
inline_css, inline_js, inline_source = css, js, fragment_source
for index, token in enumerate(tokens):
    short = '--v'+str(index)
    inline_css = inline_css.replace(token, short)
    inline_js = inline_js.replace(token, short)
    inline_source = inline_source.replace(token, short)
packed_js = base64.b64encode(gzip.compress(compact(inline_js, 'js').encode(), mtime=0)).decode()
loader = '''(async()=>{try{const bytes=Uint8Array.from(atob('%s'),c=>c.charCodeAt(0));const source=await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).text();const script=document.createElement('script');script.textContent=source;document.getElementById('ngv-desk').appendChild(script);}catch(e){document.getElementById('ngv-desk').textContent='Vorschau konnte nicht geladen werden.';console.error(e);}})();''' % packed_js
fragment = inline_source.replace('__CSS__', inline_css).replace('__JS__', loader)
assert len(fragment.encode()) < 1_000_000, len(fragment.encode())
assert '__CSS__' not in fragment and '__JS__' not in fragment
(viz/'nexgenvideo-desktop-workbench.html').write_text(fragment)
wrapper = '<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>NexGenVideo · Desktop Production Workbench</title><style>.standalone-icon-label{font-size:11px}.studio-heads:has(.standalone-icon-label){width:128px!important}.nle-icon:has(.standalone-icon-label){width:auto!important;min-width:32px!important}body{margin:0;background:#141518;padding:12px}a{color:#cfd5ef}</style></head><body>'
icons = json.loads((root/'workbench-assets/lucide-panel-icons.json').read_text())['icons']
icons.update({k: '<span class="standalone-icon-label">'+v+'</span>' for k, v in {'magnet':'Einrasten','ellipsis':'Aktionen','plus':'Spur +','lock':'Gesperrt','unlock':'Sperren','camera':'Frame','columns-2':'Vergleich','maximize':'Viewer','x':'Schließen'}.items() if k not in icons})
standalone_js = js.replace('<i data-lucide="${icon}" aria-hidden="true"></i>', '${' + json.dumps(icons) + '[icon] || `<i data-lucide="${icon}" aria-hidden="true"></i>`}')
standalone = fragment_source.replace('__CSS__',css).replace('__JS__',compact(standalone_js,'js'))
(root/'desktop-production-workbench.html').write_text(wrapper + (root/'desktop-production-workbench.spec.html').read_text() + standalone + '<script src="desktop-production-workbench.test.js"></script></body></html>')
print('Inline:', len(fragment.encode()), 'bytes')
