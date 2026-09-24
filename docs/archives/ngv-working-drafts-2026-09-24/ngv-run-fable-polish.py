import subprocess,time,json
from pathlib import Path
root=Path('<local NexGenVideo checkout>')
out=root/'docs/ui/review/polish-2026-09-19'
prompt=(out/'fable-review-prompt.txt').read_text()
schema=Path('<local home>/.codex/skills/agentic-review/review.schema.json').read_text()
import shlex
args=['claude-high5','-p',prompt,'--model','fable','--effort','high','--output-format','json','--json-schema',schema,'--tools','Read,Glob,Grep','--disable-slash-commands','--no-session-persistence','--permission-mode','plan']
start=time.time()
with (out/'fable-raw.json').open('w') as stdout,(out/'fable-stderr.log').open('w') as stderr:
 try:
  r=subprocess.run(['bash','-ic',shlex.join(args)],stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,cwd=root,timeout=900)
  rc=r.returncode
 except subprocess.TimeoutExpired:rc=124
(out/'fable-invocation.json').write_text(json.dumps({'command':'claude-high5','model':'fable','effort':'high','tools':['Read','Glob','Grep'],'permission_mode':'plan','elapsed_seconds':round(time.time()-start),'exit_code':rc},indent=2))
print('Fable reviewer finished with exit',rc,flush=True)
raise SystemExit(rc)
