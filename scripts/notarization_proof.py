"""Bind the stapled DMG ticket to the exact app it covers and verify copies installed from it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


SCHEMA = 'nexgenvideo/notarization-proof/1'
SUMMARY_SCHEMA = 'nexgenvideo/notarization-summary/1'
MODES = ('dmg-only', 'app-and-dmg')
TEAM = 'VG5X6JCLGF'
CDHASH = re.compile(r'[0-9a-f]{40}')
SHA256 = re.compile(r'[0-9a-f]{64}')
UUID = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
OWN_BINARIES = ('Contents/MacOS/NexGenVideo', 'Contents/Frameworks/libNexGenEngine.dylib',
                'Contents/Helpers/NexGenVideoDiagnostics', 'Contents/Helpers/NexGenVideoBpyStorage',
                'Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/MacOS/NexGenVideoBpyService',
                'Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/MacOS/NexGenVideoBpySupervisor',
                'Contents/XPCServices/NexGenVideoBpyService1.xpc/Contents/MacOS/NexGenVideoBpyService',
                'Contents/XPCServices/NexGenVideoBpyService1.xpc/Contents/MacOS/NexGenVideoBpySupervisor')
RUNTIME_FLAG = 0x10000
FIX = 'Rerun the candidate with notarize_app_separately=true to restore the two-submission notarization.'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def run(arguments, log=None, timeout=120):
    result = subprocess.run([str(item) for item in arguments], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=timeout)
    text = result.stdout + result.stderr
    if log is not None:
        with Path(log).open('a', encoding='utf-8') as stream:
            stream.write('$ ' + ' '.join(str(item) for item in arguments) + '\n' + text
                         + '[exit ' + str(result.returncode) + ']\n')
    return result.returncode, text


def checked(arguments, log=None, timeout=120):
    code, text = run(arguments, log, timeout)
    require(code == 0, 'Command failed: ' + ' '.join(str(item) for item in arguments) + '\n' + text)
    return text


def signature(path, log=None):
    text = checked(['codesign', '-d', '-vvv', path], log)
    values = {}
    for line in text.splitlines():
        key, separator, value = line.partition('=')
        if separator and key in ('CDHash', 'TeamIdentifier', 'CodeDirectory v'):
            values.setdefault(key, []).append(value.strip())
    hashes = values.get('CDHash', [])
    require(len(hashes) == 1 and CDHASH.fullmatch(hashes[0].lower()), 'No unique code directory hash: ' + str(path))
    teams = values.get('TeamIdentifier', [])
    flags = re.search(r'flags=(0x[0-9a-f]+)', text)
    return {'cdhash': hashes[0].lower(), 'team': teams[0] if len(teams) == 1 else '',
            'flags': int(flags.group(1), 16) if flags else None}


def tickets(log_value):
    entries = log_value.get('ticketContents')
    require(isinstance(entries, list) and entries, 'Apple log has no ticket contents')
    result = []
    for entry in entries:
        require(isinstance(entry, dict) and isinstance(entry.get('path'), str)
                and isinstance(entry.get('cdhash'), str) and CDHASH.fullmatch(entry['cdhash'].lower()),
                'Apple ticket entry is malformed')
        result.append({'path': entry['path'], 'cdhash': entry['cdhash'].lower(),
                       'arch': entry.get('arch', ''), 'digestAlgorithm': entry.get('digestAlgorithm', '')})
    return result


def covering(entries, cdhash, bundle):
    matches = [entry for entry in entries if entry['cdhash'] == cdhash and bundle in entry['path'].split('/')]
    require(matches, 'The DMG ticket does not cover ' + bundle + ' cdhash ' + cdhash + '. ' + FIX)
    return matches[0]['path']


def submission(state, uploaded):
    journal = Path(state) / (uploaded + '.json')
    require(journal.is_file() and not journal.is_symlink(), 'The uploaded DMG has no Apple submission journal')
    value = json.loads(journal.read_bytes())
    require(value.get('schema') == 'release-notary/v1' and value.get('sha256') == uploaded
            and isinstance(value.get('submissionID'), str) and UUID.fullmatch(value['submissionID']),
            'The DMG submission journal is invalid')
    return value['submissionID']


def apple_log(identifier, destination, environment):
    credentials = [environment.get(name, '') for name in ('NOTARY_KEY_FILE', 'NOTARY_KEY_ID', 'NOTARY_ISSUER')]
    require(all(credentials), 'NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER are required')
    tool = [environment['NOTARYTOOL_BIN']] if environment.get('NOTARYTOOL_BIN') else ['xcrun', 'notarytool']
    for attempt in range(3):
        if destination.exists():
            destination.unlink()
        code, text = run(tool + ['log', identifier, '--key', credentials[0], '--key-id', credentials[1],
                                 '--issuer', credentials[2], str(destination)], timeout=120)
        if code == 0 and destination.is_file():
            return json.loads(destination.read_bytes())
        print('Apple log retrieval failed (attempt ' + str(attempt + 1) + '/3): ' + text, file=sys.stderr)
    raise ValueError('Apple did not return the DMG notarization log for ' + identifier)


def record(dmg, uploaded_dmg, app, pack, state, mode, output, log_path, environment):
    require(mode in MODES, 'Unknown notarization mode')
    uploaded = sha256(uploaded_dmg)
    identifier = submission(state, uploaded)
    value = apple_log(identifier, Path(log_path), environment)
    require(value.get('jobId') == identifier and value.get('status') == 'Accepted'
            and value.get('sha256') == uploaded, 'Apple log belongs to another or a rejected DMG submission')
    entries = tickets(value)
    checked(['xcrun', 'stapler', 'validate', dmg])
    app_signature, pack_signature = signature(app), signature(pack)
    own = {}
    for relative in OWN_BINARIES:
        path = Path(app) / relative
        require(path.is_file(), 'Own signed binary is missing: ' + relative)
        own[relative] = {'cdhash': signature(path)['cdhash']}
        own[relative]['ticketPath'] = covering(entries, own[relative]['cdhash'], 'NexGenVideo.app')
    proof = {'schema': SCHEMA, 'mode': mode, 'dmgSHA256': sha256(dmg), 'uploadedDMGSHA256': uploaded,
             'submissionID': identifier, 'logSHA256': sha256(log_path),
             'app': {'cdhash': app_signature['cdhash'],
                     'ticketPath': covering(entries, app_signature['cdhash'], 'NexGenVideo.app')},
             'pack': {'cdhash': pack_signature['cdhash'],
                      'ticketPath': covering(entries, pack_signature['cdhash'], 'musicvideo.ngvpack')},
             'ownBinaries': own, 'ticketCDHashes': sorted({entry['cdhash'] for entry in entries})}
    validate(proof)
    Path(output).write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    return proof


def validate(proof, dmg_sha256=None):
    require(isinstance(proof, dict) and proof.get('schema') == SCHEMA and proof.get('mode') in MODES
            and all(SHA256.fullmatch(str(proof.get(key, ''))) for key in ('dmgSHA256', 'uploadedDMGSHA256', 'logSHA256'))
            and UUID.fullmatch(str(proof.get('submissionID', ''))), 'Notarization proof is malformed')
    covered = proof.get('ticketCDHashes')
    require(isinstance(covered, list) and covered == sorted(set(covered))
            and all(isinstance(item, str) and CDHASH.fullmatch(item) for item in covered), 'Ticket hash inventory is malformed')
    for role in ('app', 'pack'):
        require(isinstance(proof.get(role), dict) and proof[role].get('cdhash') in covered,
                'Notarization proof does not cover the ' + role)
    require(isinstance(proof.get('ownBinaries'), dict) and set(proof['ownBinaries']) == set(OWN_BINARIES)
            and all(item.get('cdhash') in covered for item in proof['ownBinaries'].values()),
            'Notarization proof does not cover every own binary')
    require(proof['ownBinaries']['Contents/MacOS/NexGenVideo']['cdhash'] == proof['app']['cdhash'],
            'App bundle and main executable hashes differ')
    if dmg_sha256 is not None:
        require(proof['dmgSHA256'] == dmg_sha256, 'Notarization proof belongs to another DMG')
    return proof


def load(path):
    return validate(json.loads(Path(path).read_bytes()))


def canonical(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def summary(proof):
    """Bounded form for size-limited producer records; the full proof travels with the DMG."""
    validate(proof)
    return {'schema': SUMMARY_SCHEMA, 'mode': proof['mode'], 'dmgSHA256': proof['dmgSHA256'],
            'submissionID': proof['submissionID'], 'proofSHA256': canonical(proof),
            'app': dict(proof['app']), 'pack': dict(proof['pack'])}


def validate_any(record, dmg_sha256=None):
    if not isinstance(record, dict) or record.get('schema') != SUMMARY_SCHEMA:
        return validate(record, dmg_sha256)
    require(set(record) == {'schema', 'mode', 'dmgSHA256', 'submissionID', 'proofSHA256', 'app', 'pack'}
            and record['mode'] in MODES and UUID.fullmatch(str(record['submissionID']))
            and all(SHA256.fullmatch(str(record[key])) for key in ('dmgSHA256', 'proofSHA256'))
            and all(isinstance(record[role], dict) and CDHASH.fullmatch(str(record[role].get('cdhash', '')))
                    for role in ('app', 'pack')), 'Notarization summary is malformed')
    if dmg_sha256 is not None:
        require(record['dmgSHA256'] == dmg_sha256, 'Notarization proof belongs to another DMG')
    return record


def signed_by_release_team(target, log=None):
    checked(['codesign', '--verify', '--deep', '--strict', '--verbose=2', target], log)
    value = signature(target, log)
    require(value['team'] == TEAM and value['flags'] is not None and value['flags'] & RUNTIME_FLAG,
            'Not signed by Developer ID team ' + TEAM + ' with the hardened runtime: ' + str(target))
    return value


def verify_copy(app, record, log=None, pack=None):
    """Prove a transferred copy is notarized: its own staple, or the DMG ticket that covers its cdhash."""
    if record is None or record['mode'] == 'app-and-dmg':
        checked(['xcrun', 'stapler', 'validate', app], log)
    result = {'mode': 'app-and-dmg' if record is None else record['mode'],
              'stapledApp': record is None or record['mode'] == 'app-and-dmg'}
    installed = signed_by_release_team(app, log)['cdhash']
    if record is not None:
        validate_any(record)
        require(installed == record['app']['cdhash'], 'Installed app is not covered by the stapled DMG ticket. ' + FIX)
        result.update(cdhash=installed, dmgSHA256=record['dmgSHA256'], submissionID=record['submissionID'])
        if pack is not None:
            require(signed_by_release_team(pack, log)['cdhash'] == record['pack']['cdhash'],
                    'Installed pack is not covered by the stapled DMG ticket. ' + FIX)
            result['packCDHash'] = record['pack']['cdhash']
    return result


def verify_installed(app, dmg, proof, log=None):
    """An app copied out of the DMG additionally requires that exact stapled DMG."""
    if proof is not None:
        validate_any(proof, sha256(dmg))
        checked(['xcrun', 'stapler', 'validate', dmg], log)
    return verify_copy(app, proof, log)


def derived_diagnostic(installed, diagnostic, mode, tree, log=None):
    """The stapled diagnostic app must be the installed DMG app plus nothing but its own ticket."""
    if mode == 'app-and-dmg':
        require(tree(installed) == tree(diagnostic), 'Diagnostic app differs from the installed DMG app')
        return tree(diagnostic)
    with tempfile.TemporaryDirectory() as directory:
        copy = Path(directory) / 'NexGenVideo.app'
        checked(['ditto', installed, copy], log)
        checked(['xcrun', 'stapler', 'staple', copy], log)
        checked(['xcrun', 'stapler', 'validate', copy], log)
        require(tree(copy) == tree(diagnostic), 'Stapled diagnostic app differs from the stapled installed DMG app')
    return tree(diagnostic)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    commands = parser.add_subparsers(dest='operation', required=True)
    create = commands.add_parser('record')
    for name in ('--dmg', '--uploaded-dmg', '--app', '--pack', '--state', '--output', '--apple-log'):
        create.add_argument(name, required=True, type=Path)
    create.add_argument('--mode', required=True, choices=MODES)
    installed = commands.add_parser('verify-installed')
    for name in ('--app', '--dmg', '--proof'):
        installed.add_argument(name, required=True, type=Path)
    derived = commands.add_parser('verify-diagnostic')
    for name in ('--installed', '--diagnostic', '--proof'):
        derived.add_argument(name, required=True, type=Path)
    args = parser.parse_args()
    if args.operation == 'record':
        record(args.dmg, args.uploaded_dmg, args.app, args.pack, args.state, args.mode, args.output,
               args.apple_log, os.environ)
    elif args.operation == 'verify-installed':
        print(json.dumps(verify_installed(args.app, args.dmg, load(args.proof)), sort_keys=True))
    else:
        sys.path.insert(0, str(Path(__file__).resolve().parent / 'external-gui'))
        from acceptance import tree_sha256
        print(derived_diagnostic(args.installed, args.diagnostic, load(args.proof)['mode'], tree_sha256))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        print('::error::' + str(error).replace('\n', ' '), file=sys.stderr)
        sys.exit(1)
