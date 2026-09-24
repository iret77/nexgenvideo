import subprocess,time,json,shlex
from pathlib import Path
root=Path('<local NexGenVideo checkout>');out=root/'docs/ui/review/acceptance-2026-09-20'
args=['claude-high5','-p',(out/'fable-verification-prompt.txt').read_text(),'--model','fable','--effort','high','--output-format','json','--json-schema',Path('<local home>/.codex/skills/agentic-review/review.schema.json').read_text(),'--tools','Read,Glob,Grep','--disable-slash-commands','--no-session-persistence','--permission-mode','plan','--strict-mcp-config','--mcp-config','{"mcpServers":{}}']
start=time.time()
with (out/'fable-verification-result.json').open('w') as stdout,(out/'fable-verification-stderr.log').open('w') as stderr:
 try:r=subprocess.run(['bash','-ic',shlex.join(args)],stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,cwd=root,timeout=900);rc=r.returncode
 except subprocess.TimeoutExpired:rc=124
(out/'fable-verification-invocation.json').write_text(json.dumps({'command':'claude-high5','model':'fable','effort':'high','tools':['Read','Glob','Grep'],'permission_mode':'plan','elapsed_seconds':round(time.time()-start),'exit_code':rc},indent=2));print('Fable verification exit',rc,flush=True)
raise SystemExit(rc)
