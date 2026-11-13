"""Build once and transfer the exact external XCTest products between CI jobs."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import tarfile
import tempfile
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import acceptance as journey

REPOSITORY = 'iret77/nexgenvideo'
ARTIFACT = 'external-gui-tests'
MEMBERS = {'tests.tar.gz', 'tests-input.json'}
WORKFLOWS = {'.github/workflows/external-gui-acceptance.yml', '.github/workflows/ci-batch.yml',
             '.github/workflows/release.yml', '.github/workflows/diagnostic-acceptance.yml'}


def require(value, message):
    journey.require(value, message)


def api(path):
    request = urllib.request.Request('https://api.github.com/repos/' + REPOSITORY + path,
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def items(path, key):
    page = 1
    while True:
        batch = api(path + f'?per_page=100&page={page}')[key]
        yield from batch
        if len(batch) < 100:
            return
        page += 1


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, target):
        return None


def download(artifact, destination):
    request = urllib.request.Request(
        f'https://api.github.com/repos/{REPOSITORY}/actions/artifacts/{artifact["id"]}/zip',
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json'})
    try:
        response = urllib.request.build_opener(NoRedirect()).open(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code != 302:
            raise ValueError('GitHub refused the exact UI test artifact') from None
        location = error.headers.get('Location', '')
        error.close()
        target = urllib.parse.urlsplit(location)
        require(target.scheme == 'https' and target.hostname and not target.username and not target.password,
                'Invalid artifact redirect')
        response = urllib.request.urlopen(location, timeout=120)
    with response, destination.open('xb') as sink:
        shutil.copyfileobj(response, sink)
    require('sha256:' + journey.sha256(destination) == artifact['digest'], 'UI test GitHub artifact digest changed')


def unpack_transfer(archive, destination):
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        require(len(entries) == len(MEMBERS) and {entry.filename for entry in entries} == MEMBERS,
                'Unexpected UI test transfer members')
        for entry in entries:
            require(not entry.is_dir() and stat.S_IFMT(entry.external_attr >> 16) in {0, stat.S_IFREG},
                    'UI test transfer contains a link or special member')
            with bundle.open(entry) as source, (destination / entry.filename).open('xb') as sink:
                shutil.copyfileobj(source, sink)


def require_origin(run, artifact, source_sha, run_id):
    require(run.get('id') == run_id and run.get('repository', {}).get('full_name') == REPOSITORY
            and run.get('head_sha') == source_sha and run.get('event') in {'workflow_dispatch', 'workflow_call'}
            and run.get('path') in WORKFLOWS, 'UI test producer has a different source or workflow')
    require(artifact.get('name') == ARTIFACT and artifact.get('expired') is False
            and artifact.get('workflow_run', {}).get('id') == run_id
            and artifact.get('workflow_run', {}).get('head_sha') == source_sha
            and type(artifact.get('id')) is int and artifact['id'] > 0
            and re.fullmatch(r'sha256:[a-f0-9]{64}', artifact.get('digest', '')),
            'UI test artifact has a different producer or expired identity')


def require_receipt(receipt, source_sha, source_files):
    require(receipt.get('schema') == 'nexgenvideo/external-tests-input/1'
            and receipt.get('sourceSHA') == source_sha and receipt.get('testFiles') == source_files
            and receipt.get('architecture') == 'arm64' and receipt.get('deploymentTarget') == '26.0'
            and isinstance(receipt.get('xcode'), str) and receipt['xcode'].startswith('Xcode ')
            and type(receipt.get('runID')) is int and receipt['runID'] > 0
            and type(receipt.get('attempt')) is int and receipt['attempt'] > 0
            and all(re.fullmatch('[a-f0-9]{64}', receipt.get(key, ''))
                    for key in ('archiveSHA256', 'productsSHA256')),
            'UI test receipt does not bind the current test inputs')
    path = receipt.get('xctestrun', '')
    require(isinstance(path, str) and PurePosixPath(path).name == path and path.endswith('.xctestrun'),
            'Invalid xctestrun location')


def require_job(job, run_id, source_sha, attempt):
    require(job.get('run_id') == run_id and job.get('head_sha') == source_sha
            and job.get('run_attempt') == attempt and job.get('status') == 'completed'
            and job.get('conclusion') == 'success' and type(job.get('id')) is int and job['id'] > 0
            and job.get('name', '').split(' / ')[-1] == 'Build external UI tests'
            and 'macrunner' in job.get('labels', []), 'UI test build job did not finish successfully')


def _safe_function(node):
    import ast
    require(isinstance(node, ast.FunctionDef) and not node.decorator_list and node.returns is None,
            'Compatibility declaration changes module execution')
    arguments = [*node.args.posonlyargs, *node.args.args, *node.args.kwonlyargs,
                 *([node.args.vararg] if node.args.vararg else []), *([node.args.kwarg] if node.args.kwarg else [])]
    require(all(argument.annotation is None for argument in arguments), 'Compatibility annotation executes at import')
    require(all(isinstance(value, ast.Constant) and isinstance(value.value, (str, int, float, bool, type(None)))
                for value in [*node.args.defaults, *filter(None, node.args.kw_defaults)]),
            'Compatibility default executes at import')


def _builder_view(text):
    import ast
    module = ast.parse(text)
    consumers = {'resolve', 'verify_input', 'consume', '_safe_function', '_builder_view',
                 '_workflow_build_view', '_guard_import_view', '_source_snapshot', '_compiled_compatibility',
                 'validate_client_selectors', 'validate_client_source', '_packaging_import_view', '_metadata_api_import_view',
                 '_native_inventory_additions', '_current_core_import_view', '_current_native_regression_ids'}
    for node in module.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in consumers:
            _safe_function(node)
    module.body = [node for node in module.body if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                   or node.name not in consumers]
    for node in module.body:
        if isinstance(node, ast.FunctionDef) and node.name == 'main':
            retained = []
            for statement in node.body:
                call = statement.value if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call) else None
                if (call is not None and isinstance(call.func, ast.Attribute) and isinstance(call.func.value, ast.Name)
                        and call.func.value.id == 'resolver' and call.func.attr == 'add_argument'
                        and len(call.args) == 1 and isinstance(call.args[0], ast.Constant)
                        and call.args[0].value == '--artifact-sha256'):
                    require(not call.keywords, 'UI test artifact selector changes parser execution')
                else:
                    retained.append(statement)
            node.body = retained
    return ast.dump(module, include_attributes=False)


def _workflow_build_view(text):
    prefix, jobs = text.split('\njobs:\n', 1)
    prefix, descriptions = re.subn(r'(?m)^(      test_bundle_run_id:\n        description:) [^\n]+$',
        r'\1 Original immutable client producer', prefix)
    require(descriptions == 1, 'Unrecognized UI test producer documentation')
    def selector(match):
        fields = {}
        for line in match[0].splitlines()[1:]:
            key, value = line.strip().split(':', 1)
            require(key not in fields, 'Duplicate UI test selector field')
            fields[key] = value.strip()
        require(set(fields) <= {'description', 'type', 'default', 'required'}
                and fields.get('type') == 'string' and fields.get('default') == "''"
                and fields.get('required', 'false') == 'false', 'UI test selectors alter build defaults')
        return ''
    prefix = re.sub(r'(?m)^      test_bundle_artifact_(?:id|sha256):\n(?:        [^\n]+\n)+', selector, prefix)
    matches = list(re.finditer(r'(?m)^  ([A-Za-z0-9_-]+):\n', jobs))
    require([match[1] for match in matches] == ['cases', 'test-build', 'test-runtime', 'acceptance'],
            'Unrecognized UI test build workflow')
    return prefix + '\njobs:\n' + ''.join(
        jobs[match.start():matches[index + 1].start() if index + 1 < len(matches) else len(jobs)]
        for index, match in enumerate(matches) if match[1] == 'test-build')


def _guard_import_view(original, current):
    import ast
    producer, consumer = ast.parse(original), ast.parse(current)
    names = {node.id for node in ast.walk(producer) if isinstance(node, ast.Name)}
    names.update(node.name for node in producer.body if isinstance(node, (ast.FunctionDef, ast.ClassDef)))
    names.update(node.asname or node.name.split('.')[0] for node in ast.walk(producer) if isinstance(node, ast.alias))
    expected = [ast.dump(node, include_attributes=False) for node in producer.body]
    retained, added = [], set()
    index = 0
    for node in consumer.body:
        value = ast.dump(node, include_attributes=False)
        if index < len(expected) and value == expected[index]:
            retained.append(node); index += 1
            continue
        _safe_function(node)
        require(not (node.name.startswith('__') and node.name.endswith('__')),
                'UI test import adds an implicit module hook')
        require(node.name not in names and node.name not in added, 'UI test import adds or replaces a reachable binding')
        added.add(node.name)
    require(index == len(expected), 'UI test shared import changes existing executable definitions')
    return ast.dump(ast.Module(body=retained, type_ignores=[]), include_attributes=False)


def _packaging_import_view(text):
    import ast
    try:
        module = ast.parse(text)
    except (SyntaxError, UnicodeDecodeError):
        raise ValueError('Packaging verifier is not valid Python') from None
    producers = {'mode_inputs', 'event_values', 'collect_original_binding'}
    addition = ast.parse("previous = original_cohort_pack_checks(mode, previous, record['signedInput'], product, previous_signed_build(previous))").body[0]
    following = ast.parse("require(record['previousNotary'].get('cohortPackChecks') == previous.get('cohortPackChecks'), 'Original cohort native pack checks changed')").body[0]
    declarations = [node.name for node in module.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]
    require(len(declarations) == len(set(declarations)), 'Duplicate packaging verifier declarations')
    kept = []
    for node in module.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in producers | {'original_cohort_pack_checks', 'validate_binding'}:
            _safe_function(node)
            if node.name == 'original_cohort_pack_checks':
                require(ast.dump(node.args, include_attributes=False) == ast.dump(
                    ast.parse('def expected(mode, previous, signed, product, original_build): pass').body[0].args,
                    include_attributes=False), 'Original pack verifier changes its import signature')
                continue
            if node.name in producers:
                node.body = [ast.Pass()]
            else:
                matches = [index for index, statement in enumerate(node.body)
                           if ast.dump(statement, include_attributes=False) == ast.dump(addition, include_attributes=False)]
                require(len(matches) == (1 if 'original_cohort_pack_checks' in declarations else 0),
                        'Original pack validator and its additive guard differ')
                if matches:
                    index = matches[0]
                    require(index + 1 < len(node.body) and ast.dump(node.body[index + 1], include_attributes=False)
                            == ast.dump(following, include_attributes=False), 'Original pack validation moved outside its guard')
                    node.body.pop(index)
        kept.append(node)
    module.body = kept
    return ast.dump(module, include_attributes=False)


def _metadata_api_import_view(raw):
    import ast
    try:
        module = ast.parse(raw)
    except (SyntaxError, UnicodeDecodeError):
        raise ValueError('Metadata transport is not valid Python') from None
    functions = [node for node in module.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == 'api']
    require(len(functions) == 1, 'Metadata transport has an ambiguous API declaration')
    legacy = ast.parse('def api(path):\n    with urllib.request.build_opener(NoRedirect()).open(github_request(path), timeout=40) as response:\n        require(response.status == 200, "GitHub metadata request did not succeed")\n        data = response.read(16 * 1024 * 1024 + 1)\n        require(len(data) <= 16 * 1024 * 1024, "GitHub metadata exceeds its bound")\n        return json.loads(data)').body[0]
    retried = ast.parse('def api(path):\n    for attempt in range(3):\n        try:\n            with urllib.request.build_opener(NoRedirect()).open(github_request(path), timeout=40) as response:\n                require(response.status == 200, "GitHub metadata request did not succeed")\n                data = response.read(16 * 1024 * 1024 + 1)\n                require(len(data) <= 16 * 1024 * 1024, "GitHub metadata exceeds its bound")\n                return json.loads(data)\n        except urllib.error.HTTPError as error:\n            if error.code not in {502, 503, 504} or attempt == 2:\n                raise\n            error.close()\n            print(f"GitHub metadata GET retry {attempt + 1}/2 after HTTP {error.code}", file=sys.stderr)\n            time.sleep(attempt + 1)').body[0]
    actual = ast.dump(functions[0], include_attributes=False)
    original_view = ast.dump(legacy, include_attributes=False)
    retry_view = ast.dump(retried, include_attributes=False)
    require(actual in {original_view, retry_view}, 'Metadata transport changes outside the exact GET retry')
    imports = [node for node in module.body if isinstance(node, ast.Import) and any(item.name == 'time' for item in node.names)]
    require(len(imports) == (1 if actual == retry_view else 0)
            and all(len(node.names) == 1 and node.names[0].asname is None for node in imports),
            'Metadata retry changes its time import')
    module.body = [legacy if node is functions[0] else node for node in module.body if node not in imports]
    return ast.dump(module, include_attributes=False)


def _source_snapshot(source_sha, paths):
    import base64
    require(re.fullmatch('[a-f0-9]{40}', source_sha), 'Invalid original UI test source')
    values = {}
    for name in [*paths, '.github/workflows/external-gui-acceptance.yml', '.github/actions/setup-xcode-27/action.yml']:
        entry = api('/contents/' + name + '?ref=' + source_sha)
        require(entry.get('type') == 'file' and entry.get('encoding') == 'base64',
                'Original UI test input is not a regular file')
        values[name] = base64.b64decode(entry['content'], validate=False)
    return values


def _native_inventory_additions(before, after):
    if before == after:return []
    expected = {'NexGenVideoTests.NativeButtonInteractionTests/' + name
                + '()/NativeButtonInteractionTests.swift:SOURCE-LINE:6' for name in (
                    'actualLegacyScrollersKeepTheEnabledUndoDiscoverable',
                    'zeroAreaButtonsWithAbsentEnabledNeverBecomeTargetsOrHideDuplicates',
                    'absentEnabledRequiresProvenZeroAreaAndReadableIdentity',
                    'unnamedButtonsRequireKnownNamesAndCannotHideNamedTargets')}
    prior = before['modules']['app']['exactEndedFunctionIDs']
    current = after['modules']['app']['exactEndedFunctionIDs']
    require(len(current) == len(set(current)) and set(current) - set(prior) == expected
            and set(prior) <= set(current), 'UI test App transition has unknown or removed native tests')
    retained = json.loads(json.dumps(after))
    retained['modules']['app']['exactEndedFunctionIDs'] = [item for item in current if item not in expected]
    retained['expectedActualExecutions'] -= len(expected)
    require(retained == before, 'UI test App transition changes existing native acceptance criteria')
    return sorted(expected)


def _current_native_regression_ids(inventory):
    import app_cohort_v2
    regressions = inventory.get('originalEightAppFailureIDsRequiredToEndWithoutIssues')
    require(isinstance(regressions, list) and len(regressions) == 8
            and all(isinstance(identity, str) for identity in regressions)
            and len(set(regressions)) == 8
            and {identity.rsplit('/', 1)[0] for identity in regressions}
                == app_cohort_v2.ORIGINAL_NATIVE_REGRESSIONS
            and set(regressions) <= set(inventory['modules']['app']['exactEndedFunctionIDs']),
            'Current GUI cohort has stale or substituted native regression IDs')


def _current_core_import_view(raw, path, *, current=False):
    import ast
    transitions = {'scripts/app_cohort_v2.py': {'<module>': [{'before': '',
                                                'after': 'ORIGINAL_NATIVE_REGRESSIONS = '
                                                         "frozenset({'NexGenVideoTests.NativeButtonInteractionTests/actualDisabledSwiftUIButtonIsExcluded()', "
                                                         "'NexGenVideoTests.NativeButtonInteractionTests/actualDuplicateButtonsCannotBecomeAUniqueTarget()', "
                                                         "'NexGenVideoTests.NativeButtonInteractionTests/actualPreparedReaderProvesItsOwnParentImageAndTrust()', "
                                                         "'NexGenVideoTests.NativeButtonInteractionTests/actualSwiftUIButtonIsDiscoveredWithoutAnExternalReader()', "
                                                         "'NexGenVideoTests.NativeButtonInteractionTests/actualTraversalBudgetCannotQualifyAPartialTree()', "
                                                         "'NexGenVideoTests.NativeButtonInteractionTests/actualWindowFrameCannotSubstituteForTheContentRoot()', "
                                                         "'NexGenVideoTests.NativeButtonInteractionTests/cancellationDuringTheLastChildMessageCannotQualifyATree()', "
                                                         "'NexGenVideoTests.NativeButtonInteractionTests/theLastChildMessageUsesItsOwnRemainingTimeout()'})",
                                                'previous': 'WHISPER_UNSIGNED_BYTES = 5501136',
                                                'following': 'def encoded(value):\n'
                                                             '    return (json.dumps(value, sort_keys=True, '
                                                             "separators=(',', ':')) + '\\n').encode()"}],
                                  'criteria': [{'before': '',
                                                'after': 'regressions = '
                                                         "expected.get('originalEightAppFailureIDsRequiredToEndWithoutIssues')\n"
                                                         'require(isinstance(regressions, list) and '
                                                         'len(regressions) == len(ORIGINAL_NATIVE_REGRESSIONS) '
                                                         'and all((isinstance(identity, str) for identity in '
                                                         'regressions)) and (len(set(regressions)) == '
                                                         "len(regressions)) and ({identity.rsplit('/', 1)[0] for "
                                                         'identity in regressions} == '
                                                         'ORIGINAL_NATIVE_REGRESSIONS) and (set(regressions) <= '
                                                         "set(expected['modules']['app']['exactEndedFunctionIDs'])), "
                                                         "'Original native regressions must name exact current "
                                                         "App execution IDs')",
                                                'previous': "for module in expected['modules'].values():\n"
                                                            '    ended, skipped = '
                                                            "(module['exactEndedFunctionIDs'], "
                                                            "module['exactSkippedFunctionIDs'])\n"
                                                            '    require(len(set(ended)) == len(ended) and '
                                                            'len(set(skipped)) == len(skipped) and (not '
                                                            "set(ended) & set(skipped)), 'Native inventory has "
                                                            "duplicate or overlapping roles')\n"
                                                            "    module['exactDiscoveredFunctionIDs'] = "
                                                            'sorted(set(ended) | set(skipped))',
                                                'following': "require(expected['expectedActualExecutions'] == "
                                                             "sum((len(module['exactEndedFunctionIDs']) for "
                                                             "module in expected['modules'].values())) + "
                                                             "len(expected['xctest']['exactIndividualPassedIDs']), "
                                                             "'Native expected count differs from independent "
                                                             "IDs')"}]},
     'scripts/compiled_app_release.py': {'selectors': [{'before': '',
                                                        'after': 'import app_cohort_v2\n'
                                                                 'if app_cohort_v2.MANIFEST.is_file():\n'
                                                                 '    app_cohort_v2.criteria()',
                                                        'previous': 'require(not any((inputs.get(name) for name '
                                                                    'in conflicts)) and '
                                                                    "inputs.get('verified_pr_run_id'), 'Compiled "
                                                                    'App selectors conflict with another '
                                                                    "continuation')",
                                                        'following': 'return value'}],
                                         'run_tests': [{'before': '',
                                                        'after': 'if dynamic:\n'
                                                                 '    import compiled_current_core_reuse\n'
                                                                 '    if '
                                                                 'compiled_current_core_reuse.matches(bound):\n'
                                                                 '        return '
                                                                 'compiled_current_core_reuse.acquire(root, '
                                                                 'bound, sys.modules[__name__])',
                                                        'previous': "dynamic = bool(bound.get('prepared', "
                                                                    "{}).get('cohortV2'))",
                                                        'following': 'if not dynamic and APP_SOURCE == '
                                                                     "compiled_core_reuse.origin()['appSourceSHA']:\n"
                                                                     '    native_guard(root)\n'
                                                                     '    bound = json.loads((root / '
                                                                     "'bound.json').read_text())\n"
                                                                     '    return '
                                                                     'compiled_core_reuse.acquire(root, bound, '
                                                                     'criteria(), sys.modules[__name__])'}],
                                         'verify_receipt': [{'before': "dynamic = receipt.get('schema') == "
                                                                       "'release-native-compiled-app/v5'",
                                                             'after': "dynamic = receipt.get('schema') in "
                                                                      "('release-native-compiled-app/v5', "
                                                                      "'release-native-compiled-app/v6')",
                                                             'previous': None,
                                                             'following': 'if dynamic:\n'
                                                                          '    import app_cohort_v2\n'
                                                                          '    value = '
                                                                          "app_cohort_v2.verify_context(receipt.get('cohortV2'))\n"
                                                                          '    expected = '
                                                                          "app_cohort_v2.criteria(receipt['cohortV2']['harnessSourceSHA'])"},
                                                            {'before': '',
                                                             'after': "if receipt.get('schema') == "
                                                                      "'release-native-compiled-app/v6':\n"
                                                                      '    import compiled_current_core_reuse\n'
                                                                      "    require(receipt.get('sourceSHA') == "
                                                                      'source == '
                                                                      "receipt['cohortV2']['harnessSourceSHA'] "
                                                                      "and type(receipt.get('runID')) is int and "
                                                                      "(receipt['runID'] == run_id) and "
                                                                      "(type(receipt.get('attempt')) is int) and "
                                                                      "(receipt['attempt'] == 1) and "
                                                                      "(receipt.get('nativeSourceObjects') == "
                                                                      'source_objects(source) == source_inputs) '
                                                                      "and (receipt.get('appSourceSHA') == "
                                                                      'app_source) and '
                                                                      "(receipt.get('compilerSHA256') == "
                                                                      'COMPILER_SHA) and '
                                                                      "(receipt.get('hostSHA256') == "
                                                                      'retained.HOST_SHA) and '
                                                                      "(receipt.get('criteriaSHA256') == "
                                                                      "criterion_sha) and (receipt.get('passed') "
                                                                      'is True) and all((type(count) is int for '
                                                                      "count in receipt.get('counts', "
                                                                      "{}).values())), 'Current retained native "
                                                                      "acceptance identity differs')\n"
                                                                      '    return '
                                                                      "compiled_current_core_reuse.verify(receipt.get('retainedNative'), "
                                                                      'receipt, sys.modules[__name__])',
                                                             'previous': 'criterion_sha = '
                                                                         "value['criteria']['sha256'] if dynamic "
                                                                         'else checksum(CRITERIA)',
                                                             'following': "if receipt.get('schema') == "
                                                                          "'release-native-compiled-app/v4':\n"
                                                                          '    import compiled_core_reuse\n'
                                                                          "    require(receipt.get('sourceSHA') "
                                                                          '== source and '
                                                                          "type(receipt.get('runID')) is int and "
                                                                          "(receipt['runID'] == run_id) and "
                                                                          "(type(receipt.get('attempt')) is int) "
                                                                          "and (receipt['attempt'] == 1) and "
                                                                          "(receipt.get('appSourceSHA') == "
                                                                          'APP_SOURCE) and '
                                                                          "(receipt.get('nativeSourceObjects') "
                                                                          '== source_objects(source) == '
                                                                          'source_objects(APP_SOURCE)) and '
                                                                          "(receipt.get('compilerSHA256') == "
                                                                          'COMPILER_SHA) and '
                                                                          "(receipt.get('hostSHA256') == "
                                                                          'retained.HOST_SHA) and '
                                                                          "(receipt.get('criteriaSHA256') == "
                                                                          'checksum(CRITERIA)) and '
                                                                          "(receipt.get('passed') is True) and "
                                                                          'all((type(value) is int for value in '
                                                                          "receipt.get('counts', {}).values())), "
                                                                          "'Retained complete native acceptance "
                                                                          "identity differs')\n"
                                                                          '    '
                                                                          "selector_identities(json.dumps(receipt.get('selected')))\n"
                                                                          '    return '
                                                                          "compiled_core_reuse.verify(receipt.get('retainedNative'), "
                                                                          'receipt, criteria(), '
                                                                          'sys.modules[__name__])'}],
                                         'verify_component_assembly': [{'before': 'if '
                                                                                  "native_evidence.get('schema') "
                                                                                  '== '
                                                                                  "'release-native-compiled-app/v5':\n"
                                                                                  '    from app_release_v2 '
                                                                                  'import verify_assembly\n'
                                                                                  '    return '
                                                                                  'verify_assembly(value, '
                                                                                  'source_sha, run_id, identity, '
                                                                                  'files, native_evidence)',
                                                                        'after': 'if '
                                                                                 "native_evidence.get('schema') "
                                                                                 'in '
                                                                                 "('release-native-compiled-app/v5', "
                                                                                 "'release-native-compiled-app/v6'):\n"
                                                                                 '    from app_release_v2 import '
                                                                                 'verify_assembly\n'
                                                                                 '    return '
                                                                                 'verify_assembly(value, '
                                                                                 'source_sha, run_id, identity, '
                                                                                 'files, native_evidence)',
                                                                        'previous': None,
                                                                        'following': 'import '
                                                                                     'consume_bpy_distributable_source '
                                                                                     'as source'}],
                                         'assemble': [{'before': 'if json.loads((root / '
                                                                 "'receipt.json').read_bytes()).get('schema') == "
                                                                 "'release-native-compiled-app/v5':\n"
                                                                 '    from app_release_v2 import assemble as '
                                                                 'assemble_current\n'
                                                                 '    return assemble_current(root)',
                                                       'after': 'if json.loads((root / '
                                                                "'receipt.json').read_bytes()).get('schema') in "
                                                                "('release-native-compiled-app/v5', "
                                                                "'release-native-compiled-app/v6'):\n"
                                                                '    from app_release_v2 import assemble as '
                                                                'assemble_current\n'
                                                                '    return assemble_current(root)',
                                                       'previous': None,
                                                       'following': 'import plistlib'}],
                                         'create_signed_input': [{'before': "if 'componentAssembly' in "
                                                                            'assembled:\n'
                                                                            '    require(type(component) is dict '
                                                                            "and (receipt.get('schema') == "
                                                                            "'release-native-compiled-app/v5' or "
                                                                            "assembled['identity']['build'] == "
                                                                            "COMPONENT_BUILD), 'Component "
                                                                            "checkpoint type or build differs')\n"
                                                                            '    '
                                                                            'verify_component_assembly(component, '
                                                                            "os.environ['GITHUB_SHA'], "
                                                                            "int(os.environ['GITHUB_RUN_ID']), "
                                                                            "assembled['identity'], "
                                                                            "{'bpy-source-receipt.json': "
                                                                            "{'sha256': checksum(build / "
                                                                            "'bpy-source/bpy-source-receipt.json')}}, "
                                                                            'receipt)\n'
                                                                            '    '
                                                                            'verify_component_materialization(component, '
                                                                            "build / 'NexGenVideo.app', build / "
                                                                            "'NexGenEngine.dSYM')\n"
                                                                            '    '
                                                                            'require(canonical_bundle_tree(build '
                                                                            "/ 'NexGenVideo.dSYM') == "
                                                                            "assembled['mainSymbolsTreeSHA256'], "
                                                                            "'Current Main symbols changed "
                                                                            "before checkpoint')\n"
                                                                            'else:\n'
                                                                            '    '
                                                                            "require(assembled['identity']['build'] "
                                                                            "!= COMPONENT_BUILD, 'Corrected "
                                                                            'compiled product lacks its actual '
                                                                            "component assembly')",
                                                                  'after': "if 'componentAssembly' in "
                                                                           'assembled:\n'
                                                                           '    require(type(component) is dict '
                                                                           "and (receipt.get('schema') in "
                                                                           "('release-native-compiled-app/v5', "
                                                                           "'release-native-compiled-app/v6') or "
                                                                           "assembled['identity']['build'] == "
                                                                           "COMPONENT_BUILD), 'Component "
                                                                           "checkpoint type or build differs')\n"
                                                                           '    '
                                                                           'verify_component_assembly(component, '
                                                                           "os.environ['GITHUB_SHA'], "
                                                                           "int(os.environ['GITHUB_RUN_ID']), "
                                                                           "assembled['identity'], "
                                                                           "{'bpy-source-receipt.json': "
                                                                           "{'sha256': checksum(build / "
                                                                           "'bpy-source/bpy-source-receipt.json')}}, "
                                                                           'receipt)\n'
                                                                           '    '
                                                                           'verify_component_materialization(component, '
                                                                           "build / 'NexGenVideo.app', build / "
                                                                           "'NexGenEngine.dSYM')\n"
                                                                           '    '
                                                                           'require(canonical_bundle_tree(build '
                                                                           "/ 'NexGenVideo.dSYM') == "
                                                                           "assembled['mainSymbolsTreeSHA256'], "
                                                                           "'Current Main symbols changed before "
                                                                           "checkpoint')\n"
                                                                           'else:\n'
                                                                           '    '
                                                                           "require(assembled['identity']['build'] "
                                                                           "!= COMPONENT_BUILD, 'Corrected "
                                                                           'compiled product lacks its actual '
                                                                           "component assembly')",
                                                                  'previous': 'component = '
                                                                              "assembled.get('componentAssembly')",
                                                                  'following': 'output.mkdir(parents=True, '
                                                                               'exist_ok=False)'}]},
     'scripts/release_checkpoint.py': {'verify_manifest': [{'before': "if evidence.get('schema') in "
                                                                      "('release-native-compiled-app/v1', "
                                                                      "'release-native-compiled-app/v2', "
                                                                      "'release-native-compiled-app/v3', "
                                                                      "'release-native-compiled-app/v4', "
                                                                      "'release-native-compiled-app/v5'):\n"
                                                                      '    from compiled_app_release import '
                                                                      'verify_receipt\n'
                                                                      '    verify_receipt(evidence, source, '
                                                                      'run_id)\n'
                                                                      "    if 'componentAssembly' in manifest:\n"
                                                                      '        from compiled_app_release import '
                                                                      'verify_component_assembly\n'
                                                                      '        '
                                                                      "verify_component_assembly(manifest['componentAssembly'], "
                                                                      'source, run_id, info, '
                                                                      "manifest.get('files', {}), evidence)\n"
                                                                      "    elif info.get('build') == '107' or "
                                                                      "evidence.get('schema') == "
                                                                      "'release-native-compiled-app/v5':\n"
                                                                      "        raise ValueError('Corrected "
                                                                      'compiled product lacks its actual '
                                                                      "component assembly')\n"
                                                                      "elif evidence.get('schema') == "
                                                                      "'release-native-scoped-repair/v1':\n"
                                                                      '    from release_test_repair import '
                                                                      'verify_receipt\n'
                                                                      '    verify_receipt(evidence, source, '
                                                                      'run_id)\n'
                                                                      "elif evidence.get('schema') == "
                                                                      "'release-native-reuse/v1':\n"
                                                                      '    from release_native_proof import '
                                                                      'SOURCE, RUN, ARTIFACT, DIGEST\n'
                                                                      "    require(evidence.get('sourceSHA') == "
                                                                      'source and '
                                                                      "evidence.get('originalSourceSHA') == "
                                                                      "SOURCE and (evidence.get('originalRun', "
                                                                      "{}).get('id') == RUN) and "
                                                                      "(evidence.get('artifact', {}).get('id') "
                                                                      '== ARTIFACT) and '
                                                                      "(evidence.get('artifactSHA256') == "
                                                                      "DIGEST) and (evidence.get('proof', "
                                                                      "{}).get('executions') == 4607), 'Reused "
                                                                      "native test evidence differs')\n"
                                                                      "elif evidence.get('schema') == "
                                                                      "'resumed-release-tests/v1':\n"
                                                                      '    from release_engine_resume import '
                                                                      'verify_completed_suite\n'
                                                                      '    '
                                                                      "verify_completed_suite(evidence.get('suite', "
                                                                      '{}), source, run_id)\n'
                                                                      'else:\n'
                                                                      "    suite = evidence.get('suite', {})\n"
                                                                      "    require(evidence.get('schema') == "
                                                                      "'fresh-release-tests/v1' and "
                                                                      "suite.get('sourceSHA') == source and "
                                                                      "(suite.get('completed') is True) and "
                                                                      "(suite.get('configuration') == 'release') "
                                                                      "and (suite.get('scope') == 'all') and "
                                                                      "(suite.get('filter') == '') and (not "
                                                                      'any((key in suite for key in '
                                                                      "('retainedBackends', "
                                                                      "'freshTestExecutions', "
                                                                      "'reusedTestExecutions')))) and "
                                                                      "all(('reusedFrom' not in phase for phase "
                                                                      "in suite.get('phases', []))), 'Signed "
                                                                      'input lacks completed fresh Release '
                                                                      "tests')",
                                                            'after': "if evidence.get('schema') in "
                                                                     "('release-native-compiled-app/v1', "
                                                                     "'release-native-compiled-app/v2', "
                                                                     "'release-native-compiled-app/v3', "
                                                                     "'release-native-compiled-app/v4', "
                                                                     "'release-native-compiled-app/v5', "
                                                                     "'release-native-compiled-app/v6'):\n"
                                                                     '    from compiled_app_release import '
                                                                     'verify_receipt\n'
                                                                     '    verify_receipt(evidence, source, '
                                                                     'run_id)\n'
                                                                     "    if 'componentAssembly' in manifest:\n"
                                                                     '        from compiled_app_release import '
                                                                     'verify_component_assembly\n'
                                                                     '        '
                                                                     "verify_component_assembly(manifest['componentAssembly'], "
                                                                     'source, run_id, info, '
                                                                     "manifest.get('files', {}), evidence)\n"
                                                                     "    elif info.get('build') == '107' or "
                                                                     "evidence.get('schema') in "
                                                                     "('release-native-compiled-app/v5', "
                                                                     "'release-native-compiled-app/v6'):\n"
                                                                     "        raise ValueError('Corrected "
                                                                     'compiled product lacks its actual '
                                                                     "component assembly')\n"
                                                                     "elif evidence.get('schema') == "
                                                                     "'release-native-scoped-repair/v1':\n"
                                                                     '    from release_test_repair import '
                                                                     'verify_receipt\n'
                                                                     '    verify_receipt(evidence, source, '
                                                                     'run_id)\n'
                                                                     "elif evidence.get('schema') == "
                                                                     "'release-native-reuse/v1':\n"
                                                                     '    from release_native_proof import '
                                                                     'SOURCE, RUN, ARTIFACT, DIGEST\n'
                                                                     "    require(evidence.get('sourceSHA') == "
                                                                     'source and '
                                                                     "evidence.get('originalSourceSHA') == "
                                                                     "SOURCE and (evidence.get('originalRun', "
                                                                     "{}).get('id') == RUN) and "
                                                                     "(evidence.get('artifact', {}).get('id') == "
                                                                     'ARTIFACT) and '
                                                                     "(evidence.get('artifactSHA256') == DIGEST) "
                                                                     "and (evidence.get('proof', "
                                                                     "{}).get('executions') == 4607), 'Reused "
                                                                     "native test evidence differs')\n"
                                                                     "elif evidence.get('schema') == "
                                                                     "'resumed-release-tests/v1':\n"
                                                                     '    from release_engine_resume import '
                                                                     'verify_completed_suite\n'
                                                                     '    '
                                                                     "verify_completed_suite(evidence.get('suite', "
                                                                     '{}), source, run_id)\n'
                                                                     'else:\n'
                                                                     "    suite = evidence.get('suite', {})\n"
                                                                     "    require(evidence.get('schema') == "
                                                                     "'fresh-release-tests/v1' and "
                                                                     "suite.get('sourceSHA') == source and "
                                                                     "(suite.get('completed') is True) and "
                                                                     "(suite.get('configuration') == 'release') "
                                                                     "and (suite.get('scope') == 'all') and "
                                                                     "(suite.get('filter') == '') and (not "
                                                                     'any((key in suite for key in '
                                                                     "('retainedBackends', "
                                                                     "'freshTestExecutions', "
                                                                     "'reusedTestExecutions')))) and "
                                                                     "all(('reusedFrom' not in phase for phase "
                                                                     "in suite.get('phases', []))), 'Signed "
                                                                     'input lacks completed fresh Release '
                                                                     "tests')",
                                                            'previous': 'evidence = '
                                                                        "manifest.get('nativeEvidence', {})",
                                                            'following': "require(set(manifest.get('files', {})) "
                                                                         "== set(FILES), 'Signed input file "
                                                                         "inventory differs')"}],
                                       'restore': [{'before': "with Path(os.environ['GITHUB_ENV']).open('a') as "
                                                              'output:\n'
                                                              "    output.write('BUILD_NUMBER=' + "
                                                              "manifest['identity']['build'] + '\\n')\n"
                                                              "    output.write('NGV_SIGNED_APP_ARCHIVE_SHA256=' "
                                                              "+ manifest['files']['NexGenVideo.zip']['sha256'] "
                                                              "+ '\\n')\n"
                                                              "    if manifest['nativeEvidence'].get('schema') "
                                                              "in ('release-native-compiled-app/v1', "
                                                              "'release-native-compiled-app/v2', "
                                                              "'release-native-compiled-app/v3', "
                                                              "'release-native-compiled-app/v4', "
                                                              "'release-native-compiled-app/v5'):\n"
                                                              '        '
                                                              "output.write('NGV_COMPILED_APP_RELEASE=true\\n')\n"
                                                              '    if retained is not None and '
                                                              '(compiled_signed_product(retained) or '
                                                              'qualified(retained)):\n'
                                                              '        '
                                                              "output.write('NGV_CURRENT_COMPILED_SOURCE_REUSE=true\\n')\n"
                                                              '    if qualified(retained):\n'
                                                              '        '
                                                              "output.write('NGV_COMPONENT_NOTARY_CONTINUATION=true\\n')\n"
                                                              '    if retained is not None and '
                                                              'cohort_signed_product(retained) and '
                                                              "retained['previousNotary'].get('cohortPackChecks'):\n"
                                                              '        '
                                                              "output.write('NGV_COHORT_PACK_CHECKS_REUSED=true\\n')",
                                                    'after': "with Path(os.environ['GITHUB_ENV']).open('a') as "
                                                             'output:\n'
                                                             "    output.write('BUILD_NUMBER=' + "
                                                             "manifest['identity']['build'] + '\\n')\n"
                                                             "    output.write('NGV_SIGNED_APP_ARCHIVE_SHA256=' "
                                                             "+ manifest['files']['NexGenVideo.zip']['sha256'] + "
                                                             "'\\n')\n"
                                                             "    if manifest['nativeEvidence'].get('schema') in "
                                                             "('release-native-compiled-app/v1', "
                                                             "'release-native-compiled-app/v2', "
                                                             "'release-native-compiled-app/v3', "
                                                             "'release-native-compiled-app/v4', "
                                                             "'release-native-compiled-app/v5', "
                                                             "'release-native-compiled-app/v6'):\n"
                                                             '        '
                                                             "output.write('NGV_COMPILED_APP_RELEASE=true\\n')\n"
                                                             '    if retained is not None and '
                                                             '(compiled_signed_product(retained) or '
                                                             'qualified(retained)):\n'
                                                             '        '
                                                             "output.write('NGV_CURRENT_COMPILED_SOURCE_REUSE=true\\n')\n"
                                                             '    if qualified(retained):\n'
                                                             '        '
                                                             "output.write('NGV_COMPONENT_NOTARY_CONTINUATION=true\\n')\n"
                                                             '    if retained is not None and '
                                                             'cohort_signed_product(retained) and '
                                                             "retained['previousNotary'].get('cohortPackChecks'):\n"
                                                             '        '
                                                             "output.write('NGV_COHORT_PACK_CHECKS_REUSED=true\\n')",
                                                    'previous': 'shutil.copyfile(payload / '
                                                                "'bpy-source-receipt.json', build / "
                                                                "'bpy-source/bpy-source-receipt.json')",
                                                    'following': "write(root / 'restored.json', {'sourceSHA': "
                                                                 "binding['sourceSHA'], 'producerRun': "
                                                                 "binding['producer']['id'], 'appTreeSHA256': "
                                                                 "manifest['appTreeSHA256'], 'identity': "
                                                                 "manifest['identity']})"}]},
     'scripts/retained_packaging.py': {'<module>': [{'before': '',
                                                     'after': 'VERIFIER_INPUTS += '
                                                              "('scripts/compiled_current_core_reuse.py', "
                                                              "'scripts/fixtures/compiled-current-core-reuse-1047.json')",
                                                     'previous': 'VERIFIER_INPUTS += '
                                                                 "('scripts/app_cohort_v2.py', "
                                                                 "'scripts/app_release_v2.py', "
                                                                 "'scripts/fixtures/app-cohort.json', "
                                                                 "'scripts/fixtures/app-cohort-native-inventory.json')",
                                                     'following': 'PACKAGING_PATHS = '
                                                                  "{'scripts/plan_dmg_capacity.py', "
                                                                  "'scripts/test_release_dmg_packaging.py', "
                                                                  "'scripts/retained_packaging.py', "
                                                                  "'scripts/test_retained_packaging.py', "
                                                                  "'scripts/release_checkpoint.py', "
                                                                  "'scripts/test_release_recovery.py', "
                                                                  "'scripts/notarize.sh', "
                                                                  "'scripts/notary_submission.py', "
                                                                  "'scripts/test_notarize.py', "
                                                                  "'scripts/workspace_native_ci.py', "
                                                                  "'scripts/test_workspace_native_ci.py', "
                                                                  "'scripts/verify_diagnostic_candidate.py', "
                                                                  "'scripts/test_diagnostic_acceptance.py', "
                                                                  "'scripts/retained_release_runtime.py', "
                                                                  "'scripts/test_retained_release_runtime.py', "
                                                                  "'scripts/release_acceptance_identity.py', "
                                                                  "'scripts/test_release_acceptance_identity.py', "
                                                                  "'scripts/external-gui/acceptance.py', "
                                                                  "'scripts/external-gui/test_bundle.py', "
                                                                  "'scripts/external-gui/transport.py', "
                                                                  "'scripts/external-gui/transport_fixture.py', "
                                                                  "'scripts/test_external_gui_test_bundle.py', "
                                                                  "'scripts/test_external_transport.py', "
                                                                  "'scripts/chat_hang_replay.py', "
                                                                  "'.github/workflows/release.yml', "
                                                                  "'.github/workflows/bpy-runtime-acceptance.yml', "
                                                                  "'.github/workflows/external-gui-acceptance.yml', "
                                                                  "'.github/workflows/chat-hang-replay.yml', "
                                                                  "'.github/workflows/private-example-analysis.yml', "
                                                                  "'.github/workflows/workspace-ui-acceptance.yml', "
                                                                  "'.github/workflows/settings-owner-acceptance.yml', "
                                                                  "'.github/workflows/ci-batch.yml', "
                                                                  "'.github/workflows/diagnostic-acceptance.yml', "
                                                                  "'scripts/test_release_workflow.py', "
                                                                  "'scripts/test_private_example_workflow.py', "
                                                                  "'scripts/test_ci_workflow.py', "
                                                                  "'.github/actions/prepare-bpy-source/action.yml', "
                                                                  "'scripts/consume_bpy_distributable_source.py', "
                                                                  "'scripts/test_consume_bpy_distributable_source.py'}"}],
                                       'signed_input': [{'before': 'if dynamic:\n'
                                                                   '    from app_release_v2 import '
                                                                   'signed_product\n'
                                                                   '    '
                                                                   "require(manifest['nativeEvidence'].get('schema') "
                                                                   "== 'release-native-compiled-app/v5', 'Typed "
                                                                   'cohort lacks its actual fresh native '
                                                                   "receipt')\n"
                                                                   '    cohort_product = '
                                                                   'signed_product(manifest)\n'
                                                                   'else:\n'
                                                                   '    cohort_product = None',
                                                         'after': 'if dynamic:\n'
                                                                  '    from app_release_v2 import '
                                                                  'signed_product\n'
                                                                  '    '
                                                                  "require(manifest['nativeEvidence'].get('schema') "
                                                                  "in ('release-native-compiled-app/v5', "
                                                                  "'release-native-compiled-app/v6'), 'Typed "
                                                                  "cohort lacks its qualified native receipt')\n"
                                                                  '    cohort_product = '
                                                                  'signed_product(manifest)\n'
                                                                  'else:\n'
                                                                  '    cohort_product = None',
                                                         'previous': 'if component_product:\n'
                                                                     '    '
                                                                     'component.verify_native_originals(producer, '
                                                                     'builder)',
                                                         'following': 'if dynamic:\n'
                                                                      '    original_notary, original_state = '
                                                                      'original_journals(producer, product, '
                                                                      'jobs, inventory, allow_pre_submit=True)\n'
                                                                      'else:\n'
                                                                      '    original_notary, original_state = '
                                                                      'original_journals(producer, product, '
                                                                      'jobs, inventory)'}],
                                       'cohort_signed_product': [{'before': "if manifest.get('nativeEvidence', "
                                                                            "{}).get('schema') != "
                                                                            "'release-native-compiled-app/v5':\n"
                                                                            '    return False',
                                                                  'after': "if manifest.get('nativeEvidence', "
                                                                           "{}).get('schema') not in "
                                                                           "('release-native-compiled-app/v5', "
                                                                           "'release-native-compiled-app/v6'):\n"
                                                                           '    return False',
                                                                  'previous': 'manifest = '
                                                                              "record.get('signedInput', "
                                                                              "{}).get('manifest', {})",
                                                                  'following': 'from app_release_v2 import '
                                                                               'signed_product'}]}}
    try:
        module = ast.parse(raw)
    except (SyntaxError, UnicodeDecodeError):
        label = ('Packaging verifier' if path == 'scripts/retained_packaging.py' else
                 'UI test Engine acquisition helper' if path == 'scripts/compiled_app_release.py' else
                 'Receipt verifier')
        raise ValueError(label + ' is not valid Python') from None
    declarations = [node.name for node in module.body if isinstance(node, ast.FunctionDef)]
    require(len(declarations) == len(set(declarations)), 'Duplicate receipt verifier declaration')
    observed = []
    for name, edits in transitions.get(path, {}).items():
        owner = module if name == '<module>' else next(
            (node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == name), None)
        require(owner is not None, 'Missing receipt verifier declaration')
        if owner is not module:
            _safe_function(owner)
        for edit in edits:
            expected = ast.parse(edit['after']).body
            replacement = ast.parse(edit['before']).body
            signature = [ast.dump(node, include_attributes=False) for node in expected]
            matches = [index for index in range(len(owner.body) - len(expected) + 1)
                       if [ast.dump(node, include_attributes=False)
                           for node in owner.body[index:index + len(expected)]] == signature]
            require(len(matches) <= 1, 'Ambiguous receipt verifier transition')
            observed.append(bool(matches))
            if matches:
                index = matches[0]
                for anchor, position in (('previous', index - 1), ('following', index + len(expected))):
                    actual = owner.body[position] if 0 <= position < len(owner.body) else None
                    expected_anchor = ast.parse(edit[anchor]).body[0] if edit[anchor] is not None else None
                    require((actual is None and expected_anchor is None) or
                            (actual is not None and expected_anchor is not None and
                             ast.dump(actual, include_attributes=False) == ast.dump(expected_anchor, include_attributes=False)),
                            'Receipt verifier transition moved outside its exact boundary')
                owner.body[index:index + len(expected)] = replacement
    require(not any(observed) and not current or all(observed), 'Incomplete current receipt verifier transition')
    return ast.unparse(module)


def _compiled_compatibility(producer_sha, producer_files, current_sha, current_files, originals, comparison):
    require(re.fullmatch('[a-f0-9]{40}', producer_sha) and producer_sha != current_sha
            and set(producer_files) <= set(current_files), 'Incomplete original UI test qualification inputs')
    require(comparison.get('base_commit', {}).get('sha') == producer_sha
            and comparison.get('merge_base_commit', {}).get('sha') == producer_sha
            and comparison.get('status') == 'ahead'
            and 0 < len(comparison.get('commits', [])) == comparison.get('total_commits') <= 250
            and comparison['commits'][-1].get('sha') == current_sha
            and len(comparison.get('files', [])) < 300, 'Original client is not a complete current ancestor')
    git = ['git', '-C', journey.REPOSITORY]
    require(journey.output([*git, 'rev-parse', 'HEAD']).decode().strip() == current_sha
            and journey.output([*git, 'merge-base', producer_sha, current_sha]).decode().strip() == producer_sha,
            'UI test consumer differs from its declared Git ancestry')
    commits = journey.output([*git, 'rev-list', producer_sha + '..' + current_sha]).decode().splitlines()
    require(len(commits) == len(set(commits)) == comparison['total_commits']
            and set(commits) == {item['sha'] for item in comparison['commits']}, 'UI test commit graph differs')
    diff = journey.output([*git, 'diff', '--no-renames', '--name-status', '-z', producer_sha, current_sha]).decode().split('\0')
    require(diff[-1] == '' and len(diff[:-1]) % 2 == 0, 'Incomplete UI test source diff')
    changes = list(zip(diff[:-1:2], diff[1:-1:2]))
    local = {name: status for status, name in changes}
    require(len(local) == len(changes) and all(status in {'A', 'M', 'D'} for status, _ in changes),
            'Ambiguous, renamed or incomplete UI test source status inventory')
    statuses = {'added': 'A', 'modified': 'M', 'removed': 'D'}
    require(len(local) == len(comparison['files'])
            and local == {item['filename']: statuses.get(item.get('status')) for item in comparison['files']}
            and all(item.get('status') in {'added', 'modified', 'removed'} and not item.get('previous_filename')
                    for item in comparison['files']), 'UI test source comparison differs')
    actual = {name: journey.output([*git, 'show', producer_sha + ':' + name]) for name in producer_files}
    require(actual == {name: originals[name] for name in producer_files}
            and {name: hashlib.sha256(raw).hexdigest() for name, raw in actual.items()} == producer_files,
            'Original UI test receipt differs from its actual Git objects')
    added_verifiers = {'scripts/compiled_current_core_reuse.py',
                      'scripts/fixtures/compiled-current-core-reuse-1047.json'}
    expected_inputs = {(journey.ROOT / name).relative_to(journey.REPOSITORY).as_posix()
                       for name in journey.TEST_INPUTS} | set(journey.SHARED_INPUTS)
    require(set(current_files) == expected_inputs and added_verifiers <= expected_inputs,
            'Current UI test receipt omits or adds declared qualification inputs')
    fixture_path = 'scripts/fixtures/compiled-current-core-reuse-1047.json'
    require(current_files[fixture_path] == '4c837a106bb3340f61efebe86b62ed7dbfe1296ccfd682972cb0407b4b76ab06',
            'Current UI test receipt changed the qualified native origin')
    import ast
    core_path = 'scripts/compiled_current_core_reuse.py'
    core_raw = journey.output([*git, 'show', current_sha + ':' + core_path])
    require(core_raw == (journey.REPOSITORY / core_path).read_bytes()
            and hashlib.sha256(core_raw).hexdigest() == current_files[core_path],
            'Current core verifier differs from its committed receipt')
    fixture_constants = [node.value for node in ast.parse(core_raw).body if isinstance(node, ast.Assign)
                         and any(isinstance(target, ast.Name) and target.id == 'FIXTURE_SHA' for target in node.targets)]
    require(len(fixture_constants) == 1 and isinstance(fixture_constants[0], ast.Constant)
            and fixture_constants[0].value == current_files[fixture_path],
            'Current core verifier no longer binds the original native fixture')
    added_inputs = set(current_files) - set(producer_files)
    require(not added_inputs or added_inputs == added_verifiers
            and all(local.get(name) == 'A' for name in added_inputs),
            'UI test receipt has unknown added verifier inputs')
    for name in added_inputs:
        raw = journey.output([*git, 'show', current_sha + ':' + name])
        require(raw == (journey.REPOSITORY / name).read_bytes()
                and hashlib.sha256(raw).hexdigest() == current_files[name],
                'Added UI test verifier differs from its committed receipt')
    helper, guard = 'scripts/external-gui/test_bundle.py', 'scripts/verify_diagnostic_candidate.py'
    cohort = 'scripts/fixtures/app-cohort.json'
    inventory_path = 'scripts/fixtures/app-cohort-native-inventory.json'
    runtime_helper = 'scripts/compiled_app_release.py'
    packaging_helper = 'scripts/retained_packaging.py'
    metadata_helper = 'scripts/retained_app_test_products.py'
    metadata_only = {'scripts/external-gui/transport.py', 'scripts/release_engine_resume.py', inventory_path, runtime_helper, packaging_helper, metadata_helper, 'scripts/app_cohort_v2.py', 'scripts/release_checkpoint.py', *added_inputs}
    require(all(producer_files[name] == digest for name, digest in current_files.items() if name not in {helper, guard, cohort, *metadata_only}),
            'Compiled UI test source, project or reachable shared helper changed')
    for name in ('scripts/app_cohort_v2.py', 'scripts/release_checkpoint.py'):
        raw = journey.output([*git, 'show', current_sha + ':' + name])
        require(raw == (journey.REPOSITORY / name).read_bytes()
                and hashlib.sha256(raw).hexdigest() == current_files[name],
                'Current receipt verifier differs from its committed receipt')
        require(_current_core_import_view(originals[name], name) == _current_core_import_view(raw, name, current=True),
                'Receipt verifier changes outside the exact current-core transition')
    current_metadata = journey.output([*git, 'show', current_sha + ':' + metadata_helper])
    require(current_metadata == (journey.REPOSITORY / metadata_helper).read_bytes()
            and hashlib.sha256(current_metadata).hexdigest() == current_files[metadata_helper],
            'Current metadata transport differs from its committed receipt')
    require(_metadata_api_import_view(originals[metadata_helper]) == _metadata_api_import_view(current_metadata),
            'Metadata transport changed a reachable guard or its import')
    import ast
    current_packaging = journey.output([*git, 'show', current_sha + ':' + packaging_helper])
    require(current_packaging == (journey.REPOSITORY / packaging_helper).read_bytes()
            and hashlib.sha256(current_packaging).hexdigest() == current_files[packaging_helper],
            'Current packaging verifier differs from its committed receipt')
    require(_packaging_import_view(_current_core_import_view(originals[packaging_helper], packaging_helper))
            == _packaging_import_view(_current_core_import_view(current_packaging, packaging_helper, current=True)),
            'Packaging verifier changed a reachable guard or its build import')
    runtime_views = []
    current_runtime = journey.output([*git, 'show', current_sha + ':' + runtime_helper])
    require(current_runtime == (journey.REPOSITORY / runtime_helper).read_bytes()
            and hashlib.sha256(current_runtime).hexdigest() == current_files[runtime_helper],
            'Current UI test runtime helper differs from its committed receipt')
    for raw in (originals[runtime_helper], current_runtime):
        try:
            module = ast.parse(_current_core_import_view(raw, runtime_helper, current=raw is current_runtime))
        except (SyntaxError, UnicodeDecodeError):
            raise ValueError('UI test Engine acquisition helper is not valid Python') from None
        carrier_names = [node.name for node in module.body if isinstance(node, ast.FunctionDef)
                         and node.name in {'engine_carrier_origin', 'retained_engine_carrier'}]
        require(len(carrier_names) == len(set(carrier_names)), 'Duplicate UI test carrier helper declaration')
        kept = []
        for node in module.body:
            if isinstance(node, ast.FunctionDef) and node.name in {'engine_carrier_origin', 'retained_engine_carrier'}:
                _safe_function(node)
                expected_args = [] if node.name == 'engine_carrier_origin' else ['root']
                require([argument.arg for argument in node.args.args] == expected_args
                        and not node.args.posonlyargs and not node.args.kwonlyargs
                        and node.args.vararg is None and node.args.kwarg is None
                        and len(node.args.defaults) == len(expected_args)
                        and all(isinstance(value, ast.Constant) and value.value is None for value in node.args.defaults),
                        'UI test carrier helper signature changes import behavior')
                continue
            if isinstance(node, ast.FunctionDef) and node.name == 'retained_engine_evidence':
                _safe_function(node)
                node.body = [ast.Pass()]
            kept.append(node)
        module.body = kept
        runtime_views.append(ast.dump(module, include_attributes=False))
    require(runtime_views[0] == runtime_views[1],
            'UI test Engine acquisition helper changes its build import or nonselected behavior')
    cohort_raw = journey.output([*git, 'show', current_sha + ':' + cohort])
    require(cohort_raw == (journey.REPOSITORY / cohort).read_bytes()
            and hashlib.sha256(cohort_raw).hexdigest() == current_files[cohort],
            'Current UI test cohort differs from its committed receipt')
    prior_cohort, current_cohort = json.loads(originals[cohort]), json.loads(cohort_raw)
    require(isinstance(prior_cohort, dict) and isinstance(current_cohort, dict)
            and 'ciPaths' in prior_cohort and 'ciPaths' in current_cohort,
            'UI test cohort metadata is incomplete')
    prior_paths, current_paths = prior_cohort.pop('ciPaths'), current_cohort.pop('ciPaths')
    for paths in (prior_paths, current_paths):
        require(isinstance(paths, list) and all(isinstance(name, str) for name in paths)
                and paths == sorted(set(paths)), 'UI test cohort CI paths are not canonical')
    app_transition = None
    if prior_cohort != current_cohort:
        mutable = {'appSourceSHA', 'appTreeSHA', 'build', 'nativeSourceObjects', 'roleSourceObjects', 'criteria'}
        require(set(prior_cohort) == set(current_cohort)
                and {name: value for name, value in prior_cohort.items() if name not in mutable}
                    == {name: value for name, value in current_cohort.items() if name not in mutable}
                and prior_cohort.get('schema') == 'native-app-cohort/v2'
                and all(re.fullmatch('[1-9][0-9]*', item.get('build', ''))
                    and all(re.fullmatch('[a-f0-9]{40}', item.get(name, '')) for name in ('appSourceSHA', 'appTreeSHA'))
                    for item in (prior_cohort, current_cohort))
                and int(current_cohort['build']) > int(prior_cohort['build'])
                and prior_cohort['appSourceSHA'] != current_cohort['appSourceSHA']
                and prior_cohort['appTreeSHA'] != current_cohort['appTreeSHA']
                and current_cohort['appSourceSHA'] in commits,
                'UI test cohort changes native or compiler identity outside an App-only transition')
        prior_roots, current_roots = prior_cohort['nativeSourceObjects'], current_cohort['nativeSourceObjects']
        require(isinstance(prior_roots, dict) and isinstance(current_roots, dict) and set(prior_roots) == set(current_roots)
                and 'Sources' in prior_roots and prior_roots['Sources'] != current_roots['Sources']
                and all(value == current_roots[name] for name, value in prior_roots.items() if name not in {'Sources', 'Tests'}),
                'UI test App-only transition changes a retained component root')
        prior_roles, current_roles = prior_cohort['roleSourceObjects'], current_cohort['roleSourceObjects']
        require(isinstance(prior_roles, dict) and isinstance(current_roles, dict)
                and set(prior_roles) == set(current_roles) == {'production', 'testable', 'tests'},
                'UI test App-only transition has an incomplete compiler role inventory')
        changed_roles = {}
        for role, before in prior_roles.items():
            after = current_roles[role]
            require(isinstance(before, dict) and isinstance(after, dict) and set(before) == set(after),
                    'UI test App-only transition changes compiler role paths')
            changed_roles[role] = sorted(name for name in before if before[name] != after[name])
            require(all((name.startswith(('Sources/NexGenVideo/', 'Tests/NexGenVideoTests/'))
                            and name in local and local[name] == 'M')
                        or (role == 'tests' and name == 'Tests/NexGenVideoTests'
                            and any(path.startswith(name + '/') for path in local)
                            and all(status == 'M' for path, status in local.items() if path.startswith(name + '/')))
                        for name in changed_roles[role]),
                    'UI test App-only transition changes a retained compiler input')
        require(changed_roles['production'] and changed_roles['testable']
                and all(name in current_paths or name.startswith(('Sources/NexGenVideo/', 'Tests/NexGenVideoTests/')) for name in local),
                'UI test App-only transition has unrelated source changes')
        import app_cohort_v2
        for declaration in (prior_cohort, current_cohort):
            source = declaration['appSourceSHA']
            require(journey.output([*git, 'rev-parse', source + '^{tree}']).decode().strip() == declaration['appTreeSHA']
                    and app_cohort_v2.objects(source, declaration['nativeSourceObjects']) == declaration['nativeSourceObjects']
                    and app_cohort_v2.objects(source, declaration['componentSourceObjects']) == declaration['componentSourceObjects']
                    and all(app_cohort_v2.objects(source, role) == role for role in declaration['roleSourceObjects'].values()),
                    'UI test App-only transition differs from its actual native Git objects')
        inventories = []
        for source, declaration in ((producer_sha, prior_cohort), (current_sha, current_cohort)):
            criterion = declaration['criteria']
            require(isinstance(criterion, dict) and set(criterion) == {'path', 'sha256'}
                    and criterion['path'] == inventory_path,
                    'UI test App-only transition has an unknown native criterion')
            raw = journey.output([*git, 'show', source + ':' + criterion['path']])
            inventory = json.loads(raw)
            files = producer_files if source == producer_sha else current_files
            expected_raw = originals[inventory_path] if source == producer_sha else (journey.REPOSITORY / inventory_path).read_bytes()
            require(raw == expected_raw and hashlib.sha256(raw).hexdigest() == criterion['sha256'] == files[inventory_path]
                    and inventory.get('schema') == 'compiled-app-native-inventory/v1'
                    and inventory.pop('appSourceSHA', None) == declaration['appSourceSHA']
                    and inventory.pop('nativeSourceObjects', None) == declaration['nativeSourceObjects'],
                    'UI test App-only transition has an unbound native inventory')
            if source == current_sha:
                _current_native_regression_ids(inventory)
            def locations(value):
                if isinstance(value, dict):return {locations(name): locations(item) for name, item in value.items()}
                if isinstance(value, list):return [locations(item) for item in value]
                if isinstance(value, str):return re.sub(r'(/NativeButtonInteractionTests\.swift:)[0-9]+(:6)$', r'\1SOURCE-LINE\2', value)
                return value
            inventories.append(locations(inventory))
        additions = _native_inventory_additions(*inventories)
        app_transition = {'schema': 'nexgenvideo/gui-app-only-cohort-transition/1',
            'producerAppSourceSHA': prior_cohort['appSourceSHA'], 'consumerAppSourceSHA': current_cohort['appSourceSHA'],
            'producerAppTreeSHA': prior_cohort['appTreeSHA'], 'consumerAppTreeSHA': current_cohort['appTreeSHA'],
            'producerBuild': prior_cohort['build'], 'consumerBuild': current_cohort['build'],
            'changedNativeRoots': sorted(name for name in prior_roots if prior_roots[name] != current_roots[name]),
            'changedRolePaths': changed_roles,
            'producerCriteriaSHA256': prior_cohort['criteria']['sha256'],
            'consumerCriteriaSHA256': current_cohort['criteria']['sha256'],
            'additionalNativeAppTests': additions,
            'newRuntimeProductProvenanceRequired': True}
    require(producer_files[inventory_path] == current_files[inventory_path] or app_transition is not None,
            'UI test native inventory changes outside an App-only transition')
    added_paths = sorted(set(current_paths) - set(prior_paths))
    require(set(prior_paths) <= set(current_paths)
            and all(name in local and local[name] in {'A', 'M'}
                    and (name in {helper, metadata_helper, *added_verifiers} or re.fullmatch(r'\.github/workflows/[A-Za-z0-9_-]+\.ya?ml', name)
                         or re.fullmatch(r'scripts/test_[A-Za-z0-9_]+\.py', name)) for name in added_paths),
            'UI test cohort adds non-CI paths or removes prior qualification paths')
    recipe = _builder_view(originals[helper].decode())
    require(recipe == _builder_view(Path(__file__).read_text()), 'UI test build closure, imports or constants changed')
    imported = _guard_import_view(originals[guard].decode(), (journey.REPOSITORY / guard).read_text())
    require(imported == _guard_import_view(originals[guard].decode(), originals[guard].decode()),
            'UI test builder import changed')
    workflow = '.github/workflows/external-gui-acceptance.yml'
    require(originals[workflow] == journey.output([*git, 'show', producer_sha + ':' + workflow]),
            'Original UI test build workflow differs from Git')
    current_workflow = journey.output([*git, 'show', current_sha + ':' + workflow])
    require(current_workflow == (journey.REPOSITORY / workflow).read_bytes(), 'Current UI test workflow is uncommitted')
    workflow_recipe = _workflow_build_view(originals[workflow].decode())
    require(workflow_recipe == _workflow_build_view(current_workflow.decode()), 'UI test build workflow changed')
    action = '.github/actions/setup-xcode-27/action.yml'
    require(originals[action] == journey.output([*git, 'show', producer_sha + ':' + action])
            == journey.output([*git, 'show', current_sha + ':' + action])
            == (journey.REPOSITORY / action).read_bytes(), 'UI test Xcode setup action changed')
    require(hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == current_files[helper]
            and hashlib.sha256((journey.REPOSITORY / guard).read_bytes()).hexdigest() == current_files[guard],
            'Current UI test compatibility source differs from its receipt')
    return {'schema': 'nexgenvideo/external-tests-compiled-compatibility/1',
        'producerSourceSHA': producer_sha, 'consumerSourceSHA': current_sha,
        'producerFiles': producer_files, 'consumerFiles': current_files,
        'originalSources': {name: raw.decode() for name, raw in originals.items()}, 'comparison': comparison,
        'packagingRuntimeHelper': {'producerSHA256': producer_files[packaging_helper],
            'consumerSHA256': current_files[packaging_helper],
            'importViewSHA256': hashlib.sha256(_packaging_import_view(current_packaging).encode()).hexdigest(),
            'newRuntimeQualificationRequired': True},
        'engineCarrierRuntimeHelper': {'producerSHA256': producer_files[runtime_helper],
            'consumerSHA256': current_files[runtime_helper],
            'importViewSHA256': hashlib.sha256(runtime_views[0].encode()).hexdigest(),
            'allowedRuntimeFunctions': ['engine_carrier_origin', 'retained_engine_carrier', 'retained_engine_evidence'],
            'newRuntimeQualificationRequired': True},
        'buildRecipeSHA256': hashlib.sha256(recipe.encode()).hexdigest(),
        'buildImportSHA256': hashlib.sha256(imported.encode()).hexdigest(),
        'buildWorkflowSHA256': hashlib.sha256(workflow_recipe.encode()).hexdigest(),
        'buildActionSHA256': hashlib.sha256(originals[action]).hexdigest(),
        'cohortMetadata': {'producerSHA256': producer_files[cohort],
            'consumerSHA256': current_files[cohort], 'addedCIPaths': added_paths,
            **({'appTransition': app_transition} if app_transition is not None else {})}}


def validate_client_selectors(run_id, artifact_id='', digest='', require_pair=True):
    require(not run_id or re.fullmatch('[1-9][0-9]*', run_id), 'UI test run ID must be positive')
    require(not artifact_id or re.fullmatch('[1-9][0-9]*', artifact_id), 'UI test artifact ID must be positive')
    require(not digest or re.fullmatch('[a-f0-9]{64}', digest), 'UI test artifact digest must be SHA-256')
    require(not (artifact_id or digest) or bool(run_id), 'UI test artifact selectors need their producer run')
    require(not digest or bool(artifact_id), 'UI test digest needs its artifact ID')
    require(not require_pair or bool(artifact_id) == bool(digest), 'UI test artifact selectors must be complete')


def validate_client_source(run_id, artifact_id, digest, source_sha):
    validate_client_selectors(run_id, artifact_id, digest)
    require(re.fullmatch('[a-f0-9]{40}', source_sha), 'UI test consumer source must be exact')
    if run_id and not artifact_id:
        run = api('/actions/runs/' + run_id)
        require(run.get('repository', {}).get('full_name') == REPOSITORY and run.get('head_sha') == source_sha,
                'A different client source requires its exact original artifact ID and digest')


def resolve(args):
    selected_digest = getattr(args, 'artifact_sha256', '') or ''
    validate_client_selectors(str(args.run_id), str(args.artifact_id or ''), selected_digest, require_pair=False)
    source_sha, source_files = journey.test_source_identity(os.environ['GITHUB_SHA'])
    run = api(f'/actions/runs/{args.run_id}')
    current = int(os.environ['GITHUB_RUN_ID'])
    require(run.get('status') == 'completed' or args.run_id == current,
            'A reused UI test producer must have finished')
    candidates = [api(f'/actions/artifacts/{args.artifact_id}')] if args.artifact_id else [
        artifact for artifact in items(f'/actions/runs/{args.run_id}/artifacts', 'artifacts')
        if artifact.get('name') == ARTIFACT and artifact.get('expired') is False]
    require(len(candidates) == 1, 'Exactly one original UI test artifact is required')
    artifact = candidates[0]
    original_source = run.get('head_sha', '')
    require_origin(run, artifact, original_source, args.run_id)
    if original_source != source_sha:
        validate_client_selectors(str(args.run_id), str(args.artifact_id or ''), selected_digest)
        require(bool(args.artifact_id) and bool(selected_digest), 'Compiled-client reuse needs its exact artifact ID and digest')
    if selected_digest:
        require(artifact['digest'] == 'sha256:' + selected_digest, 'Pinned UI test artifact digest changed')
    destination = Path(args.destination)
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination.parent / 'external-tests-transfer.zip'
    download(artifact, archive)
    unpack_transfer(archive, destination)
    receipt = journey.read_json(destination / 'tests-input.json')
    compatibility = None
    if original_source != source_sha:
        producer_files = receipt.get('testFiles')
        added_verifiers = {'scripts/compiled_current_core_reuse.py',
                          'scripts/fixtures/compiled-current-core-reuse-1047.json'}
        require(isinstance(producer_files, dict) and bool(producer_files)
                and set(producer_files) in (set(source_files), set(source_files) - added_verifiers)
                and all(isinstance(value, str) and re.fullmatch('[a-f0-9]{64}', value)
                        for value in producer_files.values()), 'Invalid original UI test source map')
        require_receipt(receipt, original_source, producer_files)
        require(receipt['runID'] == args.run_id, 'UI test receipt has another producer')
        originals = _source_snapshot(original_source, producer_files)
        compatibility = _compiled_compatibility(original_source, producer_files, source_sha,
            source_files, originals, api('/compare/' + original_source + '...' + source_sha))
    require_receipt(receipt, original_source, receipt.get('testFiles') if compatibility else source_files)
    require(receipt['runID'] == args.run_id, 'UI test receipt has another producer')
    jobs = [job for job in items(f'/actions/runs/{args.run_id}/attempts/{receipt["attempt"]}/jobs', 'jobs')
            if job.get('name', '').split(' / ')[-1] == 'Build external UI tests']
    require(len(jobs) == 1, 'Expected one original UI test build job')
    require_job(jobs[0], args.run_id, original_source, receipt['attempt'])
    require(journey.sha256(destination / 'tests.tar.gz') == receipt['archiveSHA256'], 'UI test archive changed')
    journey.write_json(destination / 'tests-producer.json', {
        'schema': 'nexgenvideo/external-tests-producer/1', 'run': run, 'artifact': artifact, 'job': jobs[0],
        'receiptSHA256': journey.sha256(destination / 'tests-input.json'),
        **({'compiledCompatibility': compatibility} if compatibility else {})})
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('producer_sha256=' + journey.sha256(destination / 'tests-producer.json') + '\n')


def unpack_products(archive, destination):
    require(not destination.exists(), 'Refusing to replace UI test products')
    with tarfile.open(archive, 'r:gz') as bundle:
        entries = bundle.getmembers()
        names = set()
        links = set()
        canonical = lambda name: unicodedata.normalize('NFD', name).casefold()
        for entry in entries:
            path = PurePosixPath(entry.name)
            require(entry.name and not path.is_absolute() and all(part not in {'', '.', '..'}
                    for part in entry.name.split('/')) and canonical(entry.name) not in names,
                    'Unsafe or duplicate UI test product path')
            names.add(canonical(entry.name))
            require(entry.isdir() or entry.isfile() or entry.issym(), 'Unsupported UI test product member')
            require(not entry.mode & 0o7000, 'Privileged UI test product mode')
            if entry.issym():
                target = posixpath.normpath(posixpath.join(str(path.parent), entry.linkname))
                require(entry.linkname and not PurePosixPath(entry.linkname).is_absolute()
                        and target != '..' and not target.startswith('../'), 'UI test product symlink escapes')
                links.add(canonical(entry.name))
        require(all(not any(canonical(str(parent)) in links for parent in PurePosixPath(name).parents)
                    for name in names), 'UI test archive writes through a symlink')
        destination.mkdir(parents=True)
        for entry in entries:
            path = destination / entry.name
            parent = destination
            for part in PurePosixPath(entry.name).parts[:-1]:
                parent = parent / part
                require(not parent.is_symlink(), 'UI test product parent is a symlink')
                parent.mkdir(exist_ok=True)
                require(parent.resolve().is_relative_to(destination.resolve()), 'UI test product parent escapes')
            if entry.isdir():
                path.mkdir(exist_ok=True)
            elif entry.isfile():
                with bundle.extractfile(entry) as source, path.open('xb') as sink:
                    shutil.copyfileobj(source, sink)
            else:
                path.symlink_to(entry.linkname)
        for entry in reversed(entries):
            path = destination / entry.name
            if not entry.issym():
                path.chmod(entry.mode)
            else:
                require(path.resolve(strict=True).is_relative_to(destination.resolve()),
                        'UI test product symlink does not resolve inside the products')


def products_sha256(root):
    records = []
    for path in sorted(root.rglob('*')):
        mode = path.lstat().st_mode
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            require(path.resolve(strict=True).is_relative_to(root.resolve()), 'UI test product symlink escapes')
            record = [relative, 'symlink', os.readlink(path)]
        elif path.is_file():
            record = [relative, stat.S_IMODE(mode), 'file', journey.sha256(path)]
        else:
            require(path.is_dir(), 'Unsupported UI test product')
            record = [relative, stat.S_IMODE(mode), 'directory']
        records.append(record)
    return hashlib.sha256(json.dumps(records, ensure_ascii=True, separators=(',', ':')).encode()).hexdigest()


def check_test_paths(xctestrun, products):
    data = plistlib.loads(xctestrun.read_bytes())
    found = set()

    def walk(value, key='', host=None):
        if isinstance(value, dict):
            host = value.get('TestHostPath', host)
            for name, child in value.items():
                walk(child, name, host)
        elif isinstance(value, list):
            for child in value:
                walk(child, key, host)
        elif isinstance(value, str) and key in {'TestBundlePath', 'TestHostPath', 'DependentProductPaths'}:
            if value.startswith('__TESTHOST__/'):
                require(isinstance(host, str) and host.startswith('__TESTROOT__/'), 'Missing relative UI test host')
                value = host + value.removeprefix('__TESTHOST__')
            require(value.startswith('__TESTROOT__/'), 'Test bundle paths must be relative to __TESTROOT__')
            relative = value.removeprefix('__TESTROOT__/')
            require('..' not in PurePosixPath(relative).parts, 'Test bundle path escapes its products')
            path = products / relative
            require(path.exists() and path.resolve().is_relative_to(products.resolve()), 'Missing relocated test product')
            found.add(key)
    walk(data)
    require({'TestBundlePath', 'TestHostPath'} <= found, 'Missing UI test bundle or test host path')


def verify_input(directory, source_sha, source_files):
    receipt = journey.read_json(directory / 'tests-input.json')
    producer = journey.read_json(directory / 'tests-producer.json')
    original_source = receipt.get('sourceSHA', '')
    compatibility = producer.get('compiledCompatibility')
    if original_source != source_sha:
        require(isinstance(compatibility, dict)
                and compatibility.get('schema') == 'nexgenvideo/external-tests-compiled-compatibility/1',
                'A different client source needs a complete compiled-input compatibility proof')
        originals = {name: text.encode() for name, text in compatibility['originalSources'].items()}
        actual = _compiled_compatibility(original_source, receipt.get('testFiles', {}), source_sha,
            source_files, originals, compatibility['comparison'])
        require(actual == compatibility, 'UI test compiled-input compatibility proof changed')
    else:
        require(compatibility is None, 'Unexpected UI test compatibility proof for identical sources')
    require_receipt(receipt, original_source, receipt.get('testFiles') if compatibility else source_files)
    require(producer.get('schema') == 'nexgenvideo/external-tests-producer/1'
            and producer.get('receiptSHA256') == journey.sha256(directory / 'tests-input.json'),
            'UI test producer receipt changed')
    require_origin(producer['run'], producer['artifact'], original_source, receipt['runID'])
    require_job(producer['job'], receipt['runID'], original_source, receipt['attempt'])
    require(journey.sha256(directory / 'tests.tar.gz') == receipt['archiveSHA256'], 'UI test archive changed')
    return receipt


def consume(directory, destination, source_sha, source_files):
    receipt = verify_input(directory, source_sha, source_files)
    if receipt['sourceSHA'] != source_sha:
        require(receipt['xcode'] == journey.output(['xcodebuild', '-version']).decode().strip(),
                'Original XCTest client has a different actual Xcode build')
    unpack_products(directory / 'tests.tar.gz', destination)
    require(products_sha256(destination) == receipt['productsSHA256'], 'UI test product tree changed')
    xctestrun = destination / receipt['xctestrun']
    check_test_paths(xctestrun, destination)
    return xctestrun, receipt


def require_runner_access(products, log):
    runners = list(products.rglob('*-Runner.app'))
    require(len(runners) == 1 and not runners[0].is_symlink(), 'Expected one independent UI test runner')
    raw = journey.output(['codesign', '-d', '--entitlements', ':-', runners[0]])
    entitlements = plistlib.loads(raw) if raw.strip() else {}
    with log.open('ab') as stream:
        stream.write(b'\nIndependent UI test runner entitlements:\n' + plistlib.dumps(entitlements) + b'\n')
    require(isinstance(entitlements, dict) and not entitlements.get('com.apple.security.app-sandbox'),
            'Independent UI test runner cannot access its project and evidence directory')


def build(args):
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'Build external UI tests only in GitHub Actions')
    source_sha, source_files = journey.test_source_identity(os.environ['GITHUB_SHA'])
    destination = Path(args.destination)
    destination.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='ngv-external-build-') as temporary:
        work = Path(temporary)
        for name in journey.TEST_INPUTS:
            target = work / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(journey.ROOT / name, target)
        _, staged_files = journey.test_source_identity(source_sha, input_root=work)
        require(staged_files == source_files, 'Staged UI test inputs differ from the committed bytes')
        journey.command(['xcodegen', 'generate', '--spec', work / 'project.yml'], destination / 'build.log')
        journey.command(['xcodebuild', 'build-for-testing', '-project', work / 'NexGenVideoExternalGUI.xcodeproj',
                         '-scheme', 'NexGenVideoExternalGUI', '-destination', 'platform=macOS,arch=arm64',
                         '-derivedDataPath', work / 'build', 'MACOSX_DEPLOYMENT_TARGET=26.0', 'ARCHS=arm64',
                         'ONLY_ACTIVE_ARCH=YES'], destination / 'build.log', timeout=240)
        products = work / 'build/Build/Products'
        require_runner_access(products, destination / 'build.log')
        paths = list(products.glob('*.xctestrun'))
        require(len(paths) == 1, 'Expected one external xctestrun bundle')
        check_test_paths(paths[0], products)
        with tarfile.open(destination / 'tests.tar.gz', 'w:gz') as archive:
            for path in sorted(products.rglob('*')):
                info = archive.gettarinfo(path, arcname=path.relative_to(products).as_posix())
                if path.is_file() and not path.is_symlink():
                    info.type = tarfile.REGTYPE
                    info.linkname = ''
                    info.size = path.stat().st_size
                    with path.open('rb') as content:
                        archive.addfile(info, content)
                else:
                    archive.addfile(info)
        journey.write_json(destination / 'tests-input.json', {
            'schema': 'nexgenvideo/external-tests-input/1', 'sourceSHA': source_sha, 'testFiles': source_files,
            'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': int(os.environ['GITHUB_RUN_ATTEMPT']),
            'architecture': 'arm64', 'deploymentTarget': '26.0',
            'xcode': journey.output(['xcodebuild', '-version']).decode().strip(),
            'xctestrun': paths[0].name, 'archiveSHA256': journey.sha256(destination / 'tests.tar.gz'),
            'productsSHA256': products_sha256(products)})


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    builder = commands.add_parser('build')
    builder.add_argument('--destination', required=True)
    resolver = commands.add_parser('resolve')
    resolver.add_argument('--run-id', type=int, required=True)
    resolver.add_argument('--artifact-id', type=int)
    resolver.add_argument('--artifact-sha256')
    resolver.add_argument('--destination', required=True)
    args = parser.parse_args()
    if args.command == 'build':
        build(args)
    else:
        resolve(args)


if __name__ == '__main__':
    main()
