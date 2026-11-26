"""Diagnose how Gatekeeper treats a stapled release DMG and its app with and without network."""
import json
import plistlib
import subprocess
import sys
import time
from pathlib import Path

import offline_gatekeeper as offline


def assess(log, label, arguments, results):
    started = time.monotonic()
    code, text = offline.run(arguments, log, timeout=180)
    results.append({'case': label, 'exit': code, 'output': text, 'seconds': round(time.monotonic() - started, 2)})


def launch(log, label, app, results):
    executable = app / 'Contents/MacOS/NexGenVideo'
    code, text = offline.run(['open', '-n', '-g', str(app)], log, timeout=60)
    time.sleep(15)
    running = offline.run(['pgrep', '-f', str(executable)], log)[0] == 0
    offline.run(['pkill', '-f', str(executable)], log)
    results.append({'case': label, 'openExit': code, 'openOutput': text, 'processStarted': running})


def cases(log, work, dmg, quarantined_dmg, unstapled, stapled, phase, results):
    assess(log, phase + ' dmg plain', ['spctl', '-a', '-vvvv', '-t', 'open', '--context', 'context:primary-signature', dmg], results)
    assess(log, phase + ' dmg quarantined', ['spctl', '-a', '-vvvv', '-t', 'open', '--context', 'context:primary-signature', quarantined_dmg], results)
    assess(log, phase + ' app unstapled', ['spctl', '-a', '-vvvv', '-t', 'exec', unstapled], results)
    assess(log, phase + ' app stapled', ['spctl', '-a', '-vvvv', '-t', 'exec', stapled], results)
    assess(log, phase + ' syspolicy_check dmg', ['syspolicy_check', 'distribution', dmg], results)
    assess(log, phase + ' syspolicy_check app unstapled', ['syspolicy_check', 'distribution', unstapled], results)
    launch(log, phase + ' launch unstapled', unstapled, results)
    launch(log, phase + ' launch stapled', stapled, results)


def main():
    source, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    log, results = [], []
    work = output / 'work'
    work.mkdir()
    found = sorted(source.rglob('*.dmg'))
    offline.run(['ls', '-laR', source], log)
    dmg = work / 'NexGenVideo.dmg'
    offline.run(['cp', found[0], dmg], log)
    offline.run(['shasum', '-a', '256', dmg], log)
    offline.run(['xcrun', 'stapler', 'staple', dmg], log)
    offline.run(['shasum', '-a', '256', dmg], log)
    status = offline.enable_gatekeeper(log)
    offline.run(['xcrun', 'stapler', 'validate', dmg], log)
    quarantined_dmg = work / 'quarantined.dmg'
    offline.run(['cp', dmg, quarantined_dmg], log)
    offline.quarantine(quarantined_dmg, log)
    mount = work / 'mount'
    mount.mkdir()
    offline.run(['hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint', mount, dmg], log)
    apps = list(mount.glob('*.app'))
    unstapled, stapled = work / 'unstapled' / 'NexGenVideo.app', work / 'stapled' / 'NexGenVideo.app'
    for target in (unstapled, stapled):
        target.parent.mkdir()
        offline.run(['ditto', apps[0], target], log)
    offline.run(['hdiutil', 'detach', mount], log)
    offline.run(['xcrun', 'stapler', 'staple', stapled], log)
    for target in (unstapled, stapled):
        offline.run(['xcrun', 'stapler', 'validate', target], log)
        offline.quarantine(target, log)
    started = time.strftime('%Y-%m-%d %H:%M:%S')
    cases(log, work, dmg, quarantined_dmg, unstapled, stapled, 'online', results)
    offline_started = time.strftime('%Y-%m-%d %H:%M:%S')
    with offline.OfflineNetwork(log, work):
        probes = offline.prove_offline(log)
        cases(log, work, dmg, quarantined_dmg, unstapled, stapled, 'offline', results)
    offline_ended = time.strftime('%Y-%m-%d %H:%M:%S')
    predicate = 'process == "syspolicyd" OR subsystem == "com.apple.syspolicy" OR process == "XProtectService" OR process == "amfid"'
    with (output / 'syspolicy.log').open('w') as out:
        subprocess.run(['log', 'show', '--info', '--debug', '--start', started, '--predicate', predicate],
                       stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=300)
    (output / 'probe.json').write_text(json.dumps({'gatekeeper': status, 'offlineProbes': probes,
        'window': [offline_started, offline_ended], 'results': results, 'log': log}, indent=1))
    for item in results:
        print(json.dumps({key: value for key, value in item.items() if key not in ('output', 'openOutput')}))


if __name__ == '__main__':
    main()
