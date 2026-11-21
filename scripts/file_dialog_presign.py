"""Exercise the actual native track assignment on the linked app before Developer ID signing."""
from contextlib import ExitStack
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import wave

from file_dialog_ui import session, start, wait_for_native
from isolated_test_home import environment
from retained_app_test_products import checksum, require


def verify_intake(app, pack, image_uuid, payload):
    from compiled_app_release import image_uuid as uuid_of, signed_payload_sha
    runner = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    work = runner / 'file-dialog-intake'
    work.mkdir()
    evidence = work / 'evidence'
    evidence.mkdir()
    track = evidence / 'Track.wav'
    with wave.open(str(track), 'wb') as wav:
        wav.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b''.join(struct.pack('<h', round(8000 * math.sin(2 * math.pi * 440 * t / 16000))) for t in range(32000)))
    with tempfile.TemporaryDirectory(dir=work) as temp, ExitStack() as stack:
        clone = Path(temp) / 'NexGenVideo.app'
        native = clone / 'Contents/MacOS/NexGenVideo'
        require(shutil.disk_usage(work).free > 512 * 1024**2, 'Insufficient scratch for the APFS clone and native evidence')
        subprocess.run(['/bin/cp', '-cR', app, clone], stdin=subprocess.DEVNULL, check=True, timeout=120)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', clone], stdin=subprocess.DEVNULL, check=True, timeout=90)
        require(uuid_of(native, 2) == image_uuid and signed_payload_sha(native, 2) == payload,
                'The test signature did not preserve the linked app payload')
        parent = {k: os.environ[k] for k in ('PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'DISPLAY') if k in os.environ}
        env = environment(parent, Path(temp) / 'home')
        env.update(NGV_WORKSPACE_UI_ACCEPTANCE='1', NGV_WORKSPACE_UI_CASE='musicvideo-intake', NGV_WORKSPACE_UI_SCALE='1.0',
                   NGV_WORKSPACE_UI_EVIDENCE=str(evidence), NGV_WORKSPACE_UI_PACK=str(pack.resolve(strict=True)))
        client = stack.enter_context(session(clone, env, evidence, 'musicvideo-intake', scale=100))
        require(client is not None, 'The reviewed file dialog XCTest is missing')
        log = stack.enter_context((evidence / 'native.log').open('xb'))
        process = start(stack, [native, '-ApplePersistenceIgnoreState', 'YES', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
                        env=env, log=log)
        require(wait_for_native(process, client, 180) == 0, 'The actual native track intake failed')
    proof = json.loads((evidence / 'hostflow-track-lyrics-result.json').read_bytes())
    rows = [r for r in proof['interactions'] if r.get('kind') == 'file-panel']
    require(len(rows) == 1 and rows[0].get('dialogTestStep') == 2 and rows[0].get('path') == track.name
            and rows[0].get('selectedURLVerified') is True and rows[0].get('nativePathEditorVerified') is True
            and (client.report / 'dialog-test-steps').read_text() == '2'
            and (evidence / 'intake-track-assigned.bin').read_bytes() == track.read_bytes(),
            'The independent input and actual track assignment differ')
    (evidence / 'verified.json').write_text(json.dumps(dict(source=os.environ['GITHUB_SHA'], runID=os.environ['GITHUB_RUN_ID'],
        imageUUID=image_uuid, mainPayloadSHA256=payload, trackSHA256=checksum(track), appPID=process.pid,
        testExit=client.process.returncode, nativeExit=process.returncode)))
