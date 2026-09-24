from pathlib import Path
import json
import os
import subprocess

base = Path(__file__).resolve().parent
review_path = os.environ.get('NGV_UI_REVIEW', 'refinement-2026-09-20')
out = base / 'review' / review_path
(out / 'legacy-studio-screenshots').mkdir(parents=True, exist_ok=True)
results = []
for name in os.environ.get('NGV_UI_SUITES', 'guards workbench polish background artwork').split():
    script = (base / f'check-desktop-production-{name}.mjs').read_text()
    script = script.replace("import {readFile,", "import {rm, readFile,")
    script = script.replace("'--disable-dev-shm-usage',", '')
    script = script.replace("['--headless=new'", "['--user-data-dir='+path.join(here,'review','.browser-'+process.pid),'--headless=new'")
    script = script.replace("'review/", "'review/" + review_path + "/legacy-")
    script = script.replace('chrome.kill();}', "chrome.kill();await rm(path.join(here,'review','.browser-'+process.pid),{recursive:true,force:true,maxRetries:3,retryDelay:100});}")
    target = base / f'.first-use-{name}.mjs'
    try:
        target.write_text(script)
        result = subprocess.run(['node', str(target)], capture_output=True, text=True, timeout=100)
        (out / f'legacy-{name}.log').write_text(result.stdout + '\n' + result.stderr)
        failures = [line for line in result.stdout.splitlines() if line.startswith(('FAIL ', 'ERROR '))]
        for line in result.stdout.splitlines():
            if line.startswith('{'):
                try:
                    failures.extend('Layout: ' + json.dumps(x) for x in json.loads(line).get('layoutFailures', []))
                except json.JSONDecodeError:
                    pass
        results.append({'suite': name, 'exit': result.returncode, 'failures': failures, 'summary': result.stdout.splitlines()[-1:]})
        print(json.dumps(results[-1]), flush=True)
    finally:
        target.unlink(missing_ok=True)
(out / 'legacy-suites.json').write_text(json.dumps(results, indent=2))
raise SystemExit(int(any(r['exit'] or r['failures'] for r in results)))
