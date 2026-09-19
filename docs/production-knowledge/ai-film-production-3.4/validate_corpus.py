"""Validate the offline knowledge dataset without running NexGenVideo."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent

def read(name):
    return json.loads((root / name).read_text())

def digest(data):
    return hashlib.sha256(data).hexdigest()

inventory = read('inventory.json')
assert inventory['sourceCommit'] is None
contracts = {c['id']: c for c in read('application-contracts.json')}
entries, originals = {}, {}
for item in inventory['files']:
    chapter = read(item['output'])
    complete = ''.join(e['contentMarkdown'] for e in chapter)
    assert [e['id'] for e in chapter] == item['entryIDs']
    assert digest(complete.encode()) == item['sha256']
    assert len(complete.encode()) == item['bytes']
    originals[item['sourcePath']] = complete.encode()
    line = 1
    for e in chapter:
        assert e['id'] not in entries
        entries[e['id']] = e
        assert e['applicationContract'] in contracts
        assert e['source']['path'] == item['sourcePath']
        assert e['source']['archiveSHA256'] == inventory['archiveSHA256']
        assert e['source']['startLine'] == line
        assert digest(e['contentMarkdown'].encode()) == e['source']['sha256']
        line += len(e['contentMarkdown'].splitlines())
        assert e['source']['endLine'] == line - 1
        assert (root / e['source']['localDocument']).is_file()
originals['LICENSE'] = (root / 'LICENSE.source.txt').read_bytes()
assert set(originals) == {x['path'] for x in inventory['sourceFiles']}
for f in inventory['sourceFiles']:
    assert digest(originals[f['path']]) == f['sha256']
    assert len(originals[f['path']]) == f['bytes']
if args.archive:
    assert digest(args.archive.read_bytes()) == inventory['archiveSHA256']
    with zipfile.ZipFile(args.archive) as archive:
        names = [n for n in archive.namelist() if not n.endswith('/')]
        assert all(n.startswith('ai-film-production/') for n in names)
        actual = {n.removeprefix('ai-film-production/'): archive.read(n) for n in names}
        assert actual == originals

assert len(entries) == inventory['counts']['sections']
assert len(inventory['files']) == inventory['counts']['documents']
assert {e['id'] for e in read('index.json')} == set(entries)
for e in entries.values():
    for dep in e['contextDependencies']:
        assert (root / dep).is_file()
    for ref in e['localReferences']:
        assert ref['entryIDs'] and set(ref['entryIDs']) <= set(entries)
for path, ids in read('locators.json')['documents'].items():
    assert path in originals and set(ids) <= set(entries)

recipes = read('blueprints.json')
assert len({r['id'] for r in recipes}) == len(recipes) == 42
assert sum(r['kind'] == 'director-recipe' for r in recipes) == 31
assert sum(r['kind'] == 'dop-signature' for r in recipes) == 11
source_recipes = {e['id'] for e in entries.values() if e['source']['path'] == 'references/director-recipes.md' and e['contentMarkdown'].startswith('### ') and 'Verify:' in e['contentMarkdown']}
assert {r['entryID'] for r in recipes} == source_recipes
baseline = root.parent / 'ai-film-production-3.1.1' / 'blueprints.json'
if baseline.exists():
    assert {r['id'] for r in recipes} == {r['id'] for r in json.loads(baseline.read_text())}
for r in recipes:
    assert r['completeRecipeMarkdown'] == entries[r['entryID']]['contentMarkdown']
    assert r['verifyText'] == r['completeRecipeMarkdown'].split('Verify:', 1)[1].strip()
    assert r['dimensions']['Verify'] == r['verifyText']
    assert re.sub(r'\s+', '', ''.join(c['sourceClause'] for c in r['verifyCriteria'])) == re.sub(r'\s+', '', r['verifyText'])
    for c in r['verifyCriteria']:
        if '[edit]' in c['sourceClause']:
            assert c['scope'] == 'assembly' and c['canTriggerReroll'] is False
        else:
            assert c['scope'] == 'take'
procedures = read('procedures.json')
assert [p['id'] for p in procedures] == [f'W{n}' for n in range(1, 11)]
for p in procedures:
    assert p['completeProcedureMarkdown'] == entries[p['entryID']]['contentMarkdown']
w10 = next(p for p in procedures if p['id'] == 'W10')['completeProcedureMarkdown']
assert len(re.findall(r'^\d+\. ', w10, re.M)) == 9 and 'animatic' in w10.lower()
for filename, key in [('tables.json', 'completeTableMarkdown'), ('templates.json', 'completeTemplateMarkdown')]:
    data = read(filename)
    assert len({x['id'] for x in data}) == len(data) == inventory['counts'][filename.split('.')[0]]
    for x in data:
        assert x[key] in entries[x['entryID']]['contentMarkdown']
units = {u['id']: u for u in read('units.json')}
assert len(units) == inventory['counts']['knowledgeUnits']
for u in units.values():
    body = entries[u['entryID']]['contentMarkdown']
    assert 0 <= u['startCharacter'] < u['endCharacter'] <= len(body)
    assert body[u['startCharacter']:u['endCharacter']].strip()
retrieval = read('retrieval-plans.json')
assert {t['id'] for t in retrieval['techniques']} == {'A', 'B', 'C'}
for t in retrieval['techniques']:
    assert set(t['techniqueEntryIDs']) <= set(entries)
    assert set(t['sharedUnitIDs']) <= set(units)
    if t['id'] in ['B', 'C']:
        assert all(not entries[eid]['title'].startswith('12h.') for eid in t['techniqueEntryIDs'])
        assert any('Lint before delivery' in entries[units[uid]['entryID']]['contentMarkdown'][units[uid]['startCharacter']:units[uid]['endCharacter']] for uid in t['sharedUnitIDs'])
manifest = read('bundle-manifest.json')
files = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p.name != 'bundle-manifest.json' and '__pycache__' not in p.parts}
assert files == {x['path'] for x in manifest['files']}
for item in manifest['files']:
    assert digest((root / item['path']).read_bytes()) == item['sha256'], item['path']
print(json.dumps({'result': 'pass', 'sourceVersion': inventory['sourceVersion'], 'archiveCompared': bool(args.archive), 'counts': inventory['counts'], 'bundleFiles': len(files), 'appExecuted': False}, indent=2))
