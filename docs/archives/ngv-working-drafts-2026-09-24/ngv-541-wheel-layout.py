import json, struct, urllib.request
from pathlib import Path
lock=json.loads(Path('<local NexGenVideo checkout>.worktrees/issue-541/Runtime/bpy/runtime-lock.json').read_text())
w=next(x for x in lock['wheels'] if x['name']=='bpy'); url=w['url']; size=w['size']
def read_range(start,end):
 req=urllib.request.Request(url,headers={'Range':f'bytes={start}-{end}'})
 with urllib.request.urlopen(req,timeout=30) as r:
  if r.status!=206: raise RuntimeError(f'Expected metadata-only HTTP206, got {r.status}')
  data=r.read(end-start+2)
  if len(data)!=end-start+1: raise RuntimeError('Unexpected range length')
  return data
last=read_range(size-65536,size-1)
i=last.rfind(b'PK\x05\x06')
if i<0: raise RuntimeError('No ZIP end record')
e=struct.unpack_from('<4s4H2LH',last,i); count, cdsize, cdoffset=e[4],e[5],e[6]
if cdsize>4*1024*1024: raise RuntimeError('Central directory beyond metadata cap')
data=read_range(cdoffset,cdoffset+cdsize-1)
names=[]; pos=0
while pos<len(data):
 if data[pos:pos+4]!=b'PK\x01\x02': raise RuntimeError('Bad central directory')
 n,x,c=struct.unpack_from('<HHH',data,pos+28)
 names.append(data[pos+46:pos+46+n].decode())
 pos+=46+n+x+c
result={'url':url,'bytesRead':65536+len(data),'entryCount':len(names),'expectedCount':count,'bpyEntryPoints':[n for n in names if n.startswith('bpy/__init__')],'bpyNativeLibraries':[n for n in names if n.startswith('bpy/lib/') and (n.endswith('.dylib') or '.so' in n)],'recordPaths':[n for n in names if n.endswith('.dist-info/RECORD')]}
Path('/tmp/ngv-541-wheel-layout.json').write_text(json.dumps(result,indent=2))
print(json.dumps({k:v for k,v in result.items() if k!='bpyNativeLibraries'},indent=2))
print('nativeLibraryCount',len(result['bpyNativeLibraries']))
