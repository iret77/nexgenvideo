"""Run one native case, preserving partial logs and exact per-case evidence."""
import json
import os
from pathlib import Path
import subprocess
import time

from workspace_ui_acceptance import ALL_CASES, SCALES, parse_events
from workspace_native_evidence import validate_case


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.pending')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def timeout_for(case):
    if case in {'filmflow', 'analysis', 'ledger', 'captionrevision', 'exportformats', 'aienhanced', 'framecontinuation',
                'nativeextension', 'animatedstill', 'frames', 'filmreview', 'corefilmreview', 'performance', 'performanceroles'}:
        return 600
    if case in {'layeredtimeline', 'timelineediting', 'chronologynegative', 'sanitynegative', 'manualvideomodes',
                'sourceoperations', 'appnle', 'genericnle', 'animationaudio', 'manualgeneration', 'textcaptions'}:
        return 360
    return 180 if case in {'mediabrowser', 'planning', 'medialibrary'} else 90


def validate_processes(case, rows, scale):
    starts = [row for row in rows if row.get('event') == 'started']
    count = 3 if case == 'generationrecovery' else 2 if case == 'exportrecovery' else 1
    return (len(starts) == count and all(row.get('case') == case and row.get('scale') == scale
            and row.get('restorationIgnored') is True for row in starts))


def run_case(executable, output, case, scale):
    if case not in ALL_CASES or scale not in SCALES:
        raise ValueError('Unknown native case or scale')
    if any(name.startswith('NGV_EXAMPLE_') for name in os.environ):
        raise ValueError('Private example inputs cannot enter public native evidence')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Each native attempt requires a fresh evidence directory')
    identity = json.loads(Path(os.environ['NGV_NATIVE_IDENTITY_FILE']).read_text())
    result = {'schema': 'nexgenvideo/native-case/1', 'case': case, 'scale': scale,
              'completed': False, 'exitCode': None, 'identity': identity, 'screenshots': [], 'events': []}
    result_path = output / 'case-result.json'
    atomic_json(result_path, result)
    log_path = output / f'scale-{round(scale * 100)}.log'
    started = time.monotonic()
    code = 1
    try:
        if case == 'generationrecovery':
            from generation_recovery_acceptance import run_generation_recovery
            text, code = run_generation_recovery(executable, output, scale)
            log_path.write_text(text)
        elif case == 'exportrecovery':
            from export_recovery_acceptance import run_export_recovery
            text, code = run_export_recovery(executable, output, scale)
            log_path.write_text(text)
        else:
            environment = {**os.environ, 'NGV_WORKSPACE_UI_ACCEPTANCE': '1',
                           'NGV_WORKSPACE_UI_EVIDENCE': str(output.resolve()), 'NGV_WORKSPACE_UI_SCALE': str(scale),
                           'NGV_WORKSPACE_UI_CASE': case, 'NGV_INSPECTOR_UI_ACCEPTANCE': '1'}
            with log_path.open('w') as log:
                with subprocess.Popen([str(executable), '-ApplePersistenceIgnoreState', 'YES',
                                       '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
                                      stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                      env=environment) as process:
                    result['processID'] = process.pid
                    atomic_json(result_path, result)
                    try:
                        code = process.wait(timeout=timeout_for(case))
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill(); process.wait(timeout=10)
                        code = 124
            text = log_path.read_text(errors='replace')
        rows = parse_events(text)
        valid, images = validate_case(case, rows, output, scale)
        result.update(events=rows, screenshots=images,
                      completed=code == 0 and validate_processes(case, rows, scale) and valid)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result['error'] = str(error)
    finally:
        result.update(exitCode=code, elapsedSeconds=time.monotonic() - started)
        atomic_json(result_path, result)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['completed'] else 1


def run_batch(executable, output):
    if any(name.startswith('NGV_EXAMPLE_') for name in os.environ):
        raise ValueError('Private example inputs cannot enter public native evidence')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Batch review requires a fresh evidence directory')
    identity = json.loads(Path(os.environ['NGV_NATIVE_IDENTITY_FILE']).read_text())
    result = {'schema': 'nexgenvideo/native-case/1', 'case': 'generationbatch', 'scale': 0,
              'identity': identity, 'completed': False, 'exitCode': None}
    atomic_json(output / 'case-result.json', result)
    environment = {**os.environ, 'NGV_SELFTEST_GENERATION_BATCH_REVIEW': '1',
                   'NGV_SELFTEST_GENERATION_BATCH_EVIDENCE': str(output.resolve())}
    started = time.monotonic()
    code = 1
    path = output / 'generation-batch-review.log'
    try:
        with path.open('w') as log, subprocess.Popen([str(executable), '-ApplePersistenceIgnoreState', 'YES',
             '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
             stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=environment) as process:
            try:
                code = process.wait(timeout=300)
            except subprocess.TimeoutExpired:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=10)
                code = 124
        result['completed'] = code == 0 and path.read_text().splitlines().count('SELFTEST_GENERATION_BATCH_REVIEW_OK') == 1
    finally:
        result.update(exitCode=code, elapsedSeconds=time.monotonic() - started)
        atomic_json(output / 'case-result.json', result)
    return 0 if result['completed'] else 1


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args()
    raise SystemExit(run_batch(args.executable, args.output))
