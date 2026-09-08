"""Offline integrity checks for knowledge authoring data; does not execute the app."""
import argparse
import hashlib
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent

def read(name):
    return json.loads((root / name).read_text())

def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()

inventory = read('inventory.json')
contracts = {c['id']: c for c in read('application-contracts.json')}
entries = {}
originals = {}
for source in inventory['files']:
    chapter = read(source['output'])
    assert source['entryIDs'] == [e['id'] for e in chapter]
    complete = ''.join(e['contentMarkdown'] for e in chapter)
    assert sha(complete) == source['sha256'], source['sourcePath']
    assert len(complete.encode()) == source['bytes']
    originals[source['sourcePath']] = complete
    line = 1
    for entry in chapter:
        assert entry['id'] not in entries
        entries[entry['id']] = entry
        assert entry['applicationContract'] in contracts
        assert entry['source']['commit'] == inventory['sourceCommit']
        assert entry['source']['path'] == source['sourcePath']
        assert entry['source']['startLine'] == line
        assert sha(entry['contentMarkdown']) == entry['source']['sha256']
        line += len(entry['contentMarkdown'].splitlines())
        assert entry['source']['endLine'] == line - 1
    if args.source:
        assert (args.source / source['sourcePath']).read_bytes() == complete.encode()

if args.source:
    actual = {str(p.relative_to(args.source)) for p in args.source.rglob('*.md')}
    assert actual == set(originals), actual.symmetric_difference(originals)
    assert (args.source / 'LICENSE').read_bytes() == (root / 'LICENSE.source.txt').read_bytes()
assert {e['id'] for e in read('index.json')} == set(entries)
assert len(entries) == inventory['counts']['sections']
for entry in entries.values():
    for ref in entry['localReferences']:
        assert ref['entryIDs'] and set(ref['entryIDs']) <= set(entries)
    for dep in entry['contextDependencies']:
        assert (root / dep).is_file()

recipes = read('blueprints.json')
assert len({r['id'] for r in recipes}) == len(recipes)
assert sum(r['kind'] == 'director-recipe' for r in recipes) == 31
assert sum(r['kind'] == 'dop-signature' for r in recipes) == 11
source_lines = originals['references/director-recipes.md'].splitlines()
expected_recipes = [line for line in source_lines if re.match(r'^\*\*.+?\*\* — ', line) and 'Verify:' in line]
assert [r['completeRecipeMarkdown'] for r in recipes] == expected_recipes
for recipe in recipes:
    assert source_lines[recipe['source']['line'] - 1] == recipe['completeRecipeMarkdown']
    assert recipe['verifyText'] == recipe['completeRecipeMarkdown'].split('Verify:', 1)[1].strip()
    assert recipe['dimensions']['Verify'] == recipe['verifyText']

procedures = read('procedures.json')
assert [p['id'] for p in procedures] == [f'W{n}' for n in range(1, 11)]
for procedure in procedures:
    assert procedure['completeProcedureMarkdown'] == entries[procedure['entryID']]['contentMarkdown']
for name, key in [('templates.json', 'completeTemplateMarkdown'), ('tables.json', 'completeTableMarkdown')]:
    collection = read(name)
    assert len({x['id'] for x in collection}) == len(collection)
    for item in collection:
        assert item[key] in entries[item['entryID']]['contentMarkdown']
    assert len(collection) == inventory['counts'][name.split('.')[0]]
units = read('units.json')
assert len({u['id'] for u in units}) == len(units) == inventory['counts']['knowledgeUnits']
for unit in units:
    body = entries[unit['entryID']]['contentMarkdown']
    assert 0 <= unit['startCharacter'] < unit['endCharacter'] <= len(body)
    assert body[unit['startCharacter']:unit['endCharacter']].strip()
for path, ids in read('locators.json')['documents'].items():
    assert path in originals and set(ids) <= set(entries)

manifest = read('bundle-manifest.json')
actual_files = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p.name != 'bundle-manifest.json' and '__pycache__' not in p.parts}
assert actual_files == {r['path'] for r in manifest['files']}
for resource in manifest['files']:
    content = (root / resource['path']).read_bytes()
    assert hashlib.sha256(content).hexdigest() == resource['sha256'], resource['path']
print(json.dumps({'result': 'pass', 'sourceCommit': inventory['sourceCommit'], 'counts': inventory['counts'], 'bundleFiles': len(actual_files), 'externalSourceCompared': bool(args.source), 'appExecuted': False}, indent=2))
