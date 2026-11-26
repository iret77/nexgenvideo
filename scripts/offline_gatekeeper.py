"""Assess and launch the app from the stapled DMG while this disposable VM has no outbound network."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


SCHEMA = 'nexgenvideo/offline-gatekeeper/1'
ANCHOR = 'com.apple/ngv-offline-gatekeeper'
APPLE_V4 = ('17.0.0.0/8',)
APPLE_V6 = ('2620:149::/32', '2403:300::/32', '2a01:b740::/29')
PROBES = ('https://api.apple-cloudkit.com/', 'https://github.com/')
PROBE_SECONDS = '3'
RESTORE_PROBE = 'https://api.github.com/'
NOTARIZED_SOURCE = 'source=Notarized Developer ID'
FIX = 'Rerun the candidate with notarize_app_separately=true to restore the two-submission notarization.'


class InfrastructureError(Exception):
    pass


def rules():
    v6 = ', '.join(APPLE_V6)
    lines = ['pass quick on lo0 all']
    for network in APPLE_V4:
        lines += [f'block return out quick inet from any to {network}', f'block drop in quick inet from {network} to any']
    lines += [f'block return out quick inet6 from any to {{ {v6} }}', f'block drop in quick inet6 from {{ {v6} }} to any',
              'block return out quick proto udp all', 'block return out quick proto tcp all flags S/SA']
    return '\n'.join(lines) + '\n'


def run(arguments, log, timeout=120, input_text=None):
    started = time.monotonic()
    try:
        result = subprocess.run([str(item) for item in arguments], input=input_text,
                                stdin=None if input_text is not None else subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=timeout)
        code, text = result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as error:
        code = 124
        text = ''.join(part.decode() if isinstance(part, bytes) else (part or '') for part in (error.stdout, error.stderr))
    entry = {'command': [str(item) for item in arguments], 'exit': code, 'output': text,
             'seconds': round(time.monotonic() - started, 3)}
    log.append(entry)
    print('$ ' + ' '.join(entry['command']) + '\n' + text + '[exit ' + str(code) + ']', flush=True)
    return code, text


def token_from(text):
    for line in text.splitlines():
        if line.strip().startswith('Token'):
            value = line.split(':', 1)[1].strip()
            if value.isdecimal():
                return value
    raise InfrastructureError('pfctl did not return an enable token')


class OfflineNetwork:
    def __init__(self, log, work):
        self.log, self.work, self.token = log, work, None

    def __enter__(self):
        code, text = run(['sudo', '-n', 'pfctl', '-E'], self.log)
        if code != 0:
            raise InfrastructureError('Cannot enable pf on the runner VM')
        self.token = token_from(text)
        code, text = run(['sudo', '-n', 'pfctl', '-sr'], self.log)
        if code != 0 or 'anchor "com.apple/*"' not in text:
            if run(['sudo', '-n', 'pfctl', '-f', '/etc/pf.conf'], self.log)[0] != 0:
                raise InfrastructureError('Cannot load the system pf ruleset that evaluates com.apple anchors')
        path = self.work / 'offline.pf'
        path.write_text(rules())
        if run(['sudo', '-n', 'pfctl', '-a', ANCHOR, '-f', path], self.log)[0] != 0:
            raise InfrastructureError('Cannot load the offline pf anchor')
        for network in APPLE_V4 + APPLE_V6:
            run(['sudo', '-n', 'pfctl', '-k', '0.0.0.0/0' if ':' not in network else '::/0', '-k', network], self.log)
            run(['sudo', '-n', 'pfctl', '-k', network], self.log)
        return self

    def __exit__(self, *_):
        restore(self.log, self.token)


def restore(log, token=None):
    run(['sudo', '-n', 'pfctl', '-a', ANCHOR, '-F', 'all'], log)
    if token:
        run(['sudo', '-n', 'pfctl', '-X', token], log)
    for attempt in range(6):
        if run(['curl', '-sS', '-o', '/dev/null', '--max-time', '20', RESTORE_PROBE], log)[0] == 0:
            return True
        time.sleep(5 * (attempt + 1))
    raise InfrastructureError('Outbound network did not return after the offline Gatekeeper check')


def prove_offline(log):
    results = {}
    for url in PROBES:
        user = run(['curl', '-sS', '-o', '/dev/null', '--max-time', PROBE_SECONDS, url], log, timeout=10)[0]
        root = run(['sudo', '-n', 'curl', '-sS', '-o', '/dev/null', '--max-time', PROBE_SECONDS, url], log, timeout=10)[0]
        results[url] = {'userExit': user, 'rootExit': root}
        if user == 0 or root == 0:
            raise InfrastructureError('Offline condition not established: ' + url + ' is still reachable')
    return results


def enable_gatekeeper(log):
    code, text = run(['spctl', '--status'], log)
    if 'assessments enabled' in text:
        return text.strip()
    for flag in ('--global-enable', '--master-enable'):
        if run(['sudo', '-n', 'spctl', flag], log)[0] == 0:
            break
    code, text = run(['spctl', '--status'], log)
    if 'assessments enabled' not in text:
        raise InfrastructureError('Gatekeeper assessments cannot be enabled on the runner VM')
    return text.strip()


def unnotarized_control(work, log):
    bundle = work / 'Unnotarized.app'
    executable = bundle / 'Contents/MacOS/Unnotarized'
    executable.parent.mkdir(parents=True)
    (bundle / 'Contents/Info.plist').write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
        '<key>CFBundleExecutable</key><string>Unnotarized</string>'
        '<key>CFBundleIdentifier</key><string>de.h5ventures.nexgenvideo.offline-control</string>'
        '<key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n')
    executable.write_bytes(Path('/usr/bin/true').read_bytes())
    executable.chmod(0o755)
    if run(['codesign', '--force', '--sign', '-', bundle], log)[0] != 0:
        raise InfrastructureError('Cannot create the unnotarized Gatekeeper control')
    quarantine(bundle, log)
    return bundle


def negative_control(bundle, log):
    code, text = run(['spctl', '-a', '-vvv', '-t', 'exec', bundle], log, timeout=60)
    if code == 0 or 'override=security disabled' in text:
        raise InfrastructureError('Gatekeeper accepted an unnotarized control; assessments are not enforced')
    return {'exit': code}


def quarantine(path, log):
    value = '0083;%x;NexGenVideo offline check;' % int(time.time())
    if run(['xattr', '-r', '-w', 'com.apple.quarantine', value, path], log)[0] != 0:
        raise InfrastructureError('Cannot apply download quarantine to ' + str(path))
    return value


def cdhash(path, log):
    code, text = run(['codesign', '-d', '-vvv', path], log)
    values = [line.split('=', 1)[1].strip().lower() for line in text.splitlines() if line.startswith('CDHash=')]
    if code != 0 or len(values) != 1:
        raise InfrastructureError('Cannot read the code directory hash of ' + str(path))
    return values[0]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def check(dmg, proof, evidence, home):
    log = []
    record = {'schema': SCHEMA, 'passed': False, 'offlineConditionProven': False, 'dmgSHA256': sha256(dmg),
              'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'rules': rules(), 'log': log}
    failure = None
    try:
        if record['dmgSHA256'] != proof['dmgSHA256']:
            raise InfrastructureError('The DMG differs from the notarized DMG in its Apple-bound proof')
        with tempfile.TemporaryDirectory(prefix='ngv-offline-') as directory:
            work = Path(directory)
            image = work / 'download' / 'NexGenVideo.dmg'
            image.parent.mkdir()
            if run(['ditto', dmg, image], log)[0] != 0:
                raise InfrastructureError('Cannot copy the DMG')
            record['dmgQuarantine'] = quarantine(image, log)
            mount = work / 'volume'
            mount.mkdir()
            installed = work / 'Applications' / 'NexGenVideo.app'
            pack = work / 'Plug-Ins' / 'musicvideo.ngvpack'
            installed.parent.mkdir()
            pack.parent.mkdir()
            if run(['hdiutil', 'attach', image, '-nobrowse', '-readonly', '-noverify', '-mountpoint', mount], log)[0] != 0:
                raise InfrastructureError('Cannot mount the quarantined DMG')
            try:
                if run(['ditto', mount / 'NexGenVideo.app', installed], log)[0] != 0 or \
                        run(['ditto', mount / 'musicvideo.ngvpack', pack], log)[0] != 0:
                    raise InfrastructureError('Cannot copy the app and pack out of the mounted DMG')
            finally:
                run(['hdiutil', 'detach', mount], log)
            record['inheritedQuarantine'] = run(['xattr', '-p', 'com.apple.quarantine', installed], log)[0] == 0
            quarantine(installed, log)
            quarantine(pack, log)
            record['appCDHash'] = cdhash(installed, log)
            if record['appCDHash'] != proof['app']['cdhash']:
                raise InfrastructureError('The DMG app differs from the app in the Apple-bound proof')
            control = unnotarized_control(work, log)
            record['gatekeeperStatus'] = enable_gatekeeper(log)
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), NGV_SELFTEST_PACK=str(pack))
            with OfflineNetwork(log, work):
                blocked = time.monotonic()
                record['offlineProbes'] = prove_offline(log)
                record['negativeControl'] = negative_control(control, log)
                record['offlineConditionProven'] = True
                code, text = run(['spctl', '-a', '-vvv', '-t', 'open', '--context', 'context:primary-signature', image],
                                 log, timeout=60)
                record['dmgAssessment'] = {'exit': code, 'notarized': NOTARIZED_SOURCE in text.splitlines()}
                if code != 0 or not record['dmgAssessment']['notarized']:
                    raise ValueError('Gatekeeper rejected the stapled DMG offline. ' + FIX)
                code, text = run(['spctl', '-a', '-vvv', '-t', 'exec', installed], log, timeout=60)
                record['appAssessment'] = {'exit': code, 'notarized': NOTARIZED_SOURCE in text.splitlines()}
                if code != 0 or not record['appAssessment']['notarized']:
                    raise ValueError('Gatekeeper rejected the app copied from the stapled DMG offline. ' + FIX)
                started = time.monotonic()
                launched = subprocess.run([str(installed / 'Contents/MacOS/NexGenVideo')], stdin=subprocess.DEVNULL,
                                          capture_output=True, text=True, timeout=120, env=environment)
                output = launched.stdout + launched.stderr
                log.append({'command': ['NGV_SELFTEST_PACK=' + str(pack), str(installed / 'Contents/MacOS/NexGenVideo')],
                            'exit': launched.returncode, 'output': output,
                            'seconds': round(time.monotonic() - started, 3)})
                print(output, flush=True)
                record['launch'] = {'exit': launched.returncode, 'packLoaded': 'SELFTEST_PACK_OK loaded musicvideo' in output}
                record['blockedSeconds'] = round(time.monotonic() - blocked, 3)
                if launched.returncode != 0 or not record['launch']['packLoaded']:
                    raise ValueError('The quarantined app from the stapled DMG did not launch and load its pack offline. ' + FIX)
            record['passed'] = True
    except (InfrastructureError, ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        failure = error
        record['failure'] = {'kind': 'infrastructure' if isinstance(error, (InfrastructureError, KeyError)) else 'gatekeeper',
                             'message': str(error)}
    finally:
        record['completedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        evidence.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    if failure is not None:
        kind = record['failure']['kind']
        prefix = 'Offline Gatekeeper check could not run' if kind == 'infrastructure' else 'Offline Gatekeeper check failed'
        raise SystemExit('::error::' + prefix + ': ' + str(failure))
    return record


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    commands = parser.add_subparsers(dest='operation', required=True)
    assess = commands.add_parser('check')
    assess.add_argument('--dmg', required=True, type=Path)
    assess.add_argument('--proof', required=True, type=Path)
    assess.add_argument('--evidence', required=True, type=Path)
    assess.add_argument('--home', required=True, type=Path)
    commands.add_parser('restore')
    args = parser.parse_args()
    if args.operation == 'check':
        from notarization_proof import load
        check(args.dmg, load(args.proof), args.evidence, args.home)
    else:
        log = []
        try:
            restore(log)
        except InfrastructureError as error:
            raise SystemExit('::error::' + str(error))


if __name__ == '__main__':
    sys.exit(main())
