"""Stop and terminate only this driver's encoder process, then reopen its genuine recovery state."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def run_export_recovery(executable, output, scale):
    output = Path(output).resolve(); directory = output / ('export-recovery-' + str(round(scale * 100)))
    chunks = []
    for stage in ('prepare', 'resume'):
        environment = {**os.environ, 'NGV_WORKSPACE_UI_ACCEPTANCE': '1', 'NGV_WORKSPACE_UI_EVIDENCE': str(output),
            'NGV_WORKSPACE_UI_SCALE': str(scale), 'NGV_WORKSPACE_UI_CASE': 'exportrecovery',
            'NGV_EXPORT_RECOVERY_STAGE': stage, 'NGV_INSPECTOR_UI_ACCEPTANCE': '1'}
        logfile = output / ('export-recovery-' + str(round(scale * 100)) + '-' + stage + '.log')
        stopped, code = False, 124
        with logfile.open('w') as log:
            process = subprocess.Popen([str(executable), '-ApplePersistenceIgnoreState', 'YES', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=environment, text=True)
            try:
                if stage == 'prepare':
                    deadline = time.monotonic() + 240
                    ready = directory / 'process-stop-ready'
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            code = process.returncode or 1; break
                        if ready.exists():
                            pid, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
                            if pid == process.pid and os.WIFSTOPPED(status) and os.WSTOPSIG(status) == signal.SIGSTOP:
                                state = json.loads((directory / 'restart-state.json').read_text())
                                if state['processID'] != process.pid: raise ValueError('The stopped process does not own the real export job')
                                stopped = True; process.kill(); code = process.wait(timeout=10); break
                            if pid == process.pid and (os.WIFEXITED(status) or os.WIFSIGNALED(status)):
                                process.returncode = os.waitstatus_to_exitcode(status); code = process.returncode or 1; break
                        time.sleep(.05)
                else:
                    code = process.wait(timeout=180)
            except (subprocess.TimeoutExpired, OSError, ValueError, KeyError):
                code = 124
            finally:
                if process.poll() is None:
                    process.kill(); process.wait(timeout=10)
        chunks.append(logfile.read_text(errors='replace'))
        chunks.append(json.dumps({'event': 'export-recovery-process', 'stage': stage, 'scale': scale,
            'processID': process.pid, 'exitCode': code, 'observedSIGSTOP': stopped}) + '\n')
        if stage == 'prepare' and (not stopped or code != -signal.SIGKILL): return ''.join(chunks), code if code > 0 else 1
        if stage == 'resume' and code: return ''.join(chunks), code
    return ''.join(chunks), 0
