import base64
import binascii
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import uuid
import zlib

import bpy_metal_diagnostic as diagnostic


class MetalControlTests(unittest.TestCase):
    raw_scene = (b'    private static func acceptanceSceneSource() -> String {\n        """\n'
                 b'        import json\n        text = "line\\\\n"\n        """\n    }')

    @staticmethod
    def raster(uniform=False):
        def chunk(kind, payload):
            return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', binascii.crc32(kind + payload) & 0xffffffff)
        rows = []
        for y in range(360):
            row = b'\x60\x70\x80' * 640 if uniform else bytes(value for x in range(640) for value in (x % 256, y % 256, (x + y) % 256))
            rows.append(b'\0' + row)
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 640, 360, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))

    @staticmethod
    def supervision(pid=123):
        return dict(pid=pid, timedOut=False, exitCode=0, reaped=True, cleanupErrors=[],
                    startedWall=1000, endedWall=1005, startedMonotonic=100, endedMonotonic=105, elapsedSeconds=5)

    @staticmethod
    def result(executable, bindings, digest, source='a' * 40):
        return dict(schema='nexgenvideo/bpy-metal-control-result/1', scope=diagnostic.SCOPE,
            appSourceSHA=source, sceneSHA256=digest, pid=123, executable=str(executable),
            state='completed', python='3.13.15', bpy='5.2.2', engine='CYCLES', samples=8,
            device='GPU', computeDeviceType='METAL', devices=[dict(type='METAL', name='fixture GPU', use=True)],
            phases=[dict(state=state, wall=1000 + i, monotonic=100 + i)
                    for i, state in enumerate(['loading', 'runtimeLoaded', 'rendering', 'completed'])], **bindings)

    @staticmethod
    def fake_app(base):
        app = base / 'Fixture.app'
        runtime = app / 'Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/Resources/BpyRuntime'
        (runtime / 'python/bin').mkdir(parents=True)
        (runtime / 'site-packages/bpy').mkdir(parents=True)
        executable = runtime / 'python/bin/python3.13'
        executable.write_bytes(struct.pack('<8I', 0xFEEDFACF, 0x100000c, 0, 2, 1, 24, 0, 0)
                               + struct.pack('<II', 0x1b, 24) + uuid.uuid4().bytes)
        executable.chmod(0o755)
        worker, module = runtime / 'worker.py', runtime / 'site-packages/bpy/__init__.so'
        worker.write_bytes(b'pass\n')
        module.write_bytes(b'original fixture native module')
        with (app / 'Contents/Info.plist').open('wb') as handle:
            plistlib.dump(dict(NGVSourceCommit='a' * 40), handle)
        return app, executable, worker, module

    def test_exact_scene_source_binding_rejects_foreign_and_unsupported_swift(self):
        raw = self.raw_scene
        self.assertEqual(diagnostic.scene_source(raw), b'import json\ntext = "line\\n"')
        for changed in (raw + raw, raw.replace(b'import json', b'\\(interpolation)'),
                        raw.replace(b'        import', b'      import'), raw.replace(b'\\\\n', b'\\n')):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                diagnostic.scene_source(changed)
        blob = hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
        record = dict(path=diagnostic.SOURCE_PATH, encoding='base64', size=len(raw), sha=blob,
                      content=base64.b64encode(raw).decode())
        with mock.patch.dict(os.environ, {'GH_TOKEN': 'fixture-token'}):
            opener = mock.Mock()
            opener.open.return_value = io.BytesIO(json.dumps(record).encode())
            with mock.patch.object(diagnostic.urllib.request, 'build_opener', return_value=opener) as factory:
                self.assertEqual(diagnostic.original_source('a' * 40), (raw, blob))
                self.assertIsInstance(factory.call_args.args[0], diagnostic.SourceRedirect)
                request = opener.open.call_args.args[0]
                self.assertEqual(request.full_url, 'https://api.github.com/repos/iret77/nexgenvideo/contents/'
                                 + diagnostic.SOURCE_PATH + '?ref=' + 'a' * 40)
            for key, value in [('path', 'foreign.swift'), ('encoding', 'raw'), ('size', len(raw) + 1), ('sha', 'b' * 40)]:
                opener = mock.Mock()
                opener.open.return_value = io.BytesIO(json.dumps(dict(record, **{key: value})).encode())
                with self.subTest(key=key), mock.patch.object(diagnostic.urllib.request, 'build_opener',
                        return_value=opener), self.assertRaises(ValueError):
                    diagnostic.original_source('a' * 40)
            with mock.patch.object(diagnostic.urllib.request, 'build_opener') as opener, self.assertRaises(ValueError):
                diagnostic.original_source('../foreign')
            opener.assert_not_called()
            self.assertNotIn('fixture-token', diagnostic.error_text(ValueError('Authorization: Bearer fixture-token')))
        with self.assertRaises(ValueError):
            diagnostic.SourceRedirect().redirect_request(None, None, 302, '', {}, 'https://foreign.invalid')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'source.json'
            with mock.patch.object(diagnostic, 'original_source', return_value=(raw, blob)):
                diagnostic.prefetch_source('a' * 40, path)
            self.assertEqual(diagnostic.source_input('a' * 40, path), (raw, blob))
            original = json.loads(path.read_text())
            for key, value in [('sourceSHA', 'b' * 40), ('path', 'foreign.swift'), ('blobSHA', 'c' * 40)]:
                path.write_text(json.dumps(dict(original, **{key: value})))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    diagnostic.source_input('a' * 40, path)
        compile(diagnostic.CHILD, '<metal-control-child>', 'exec')
        current = (Path(__file__).resolve().parents[1] / diagnostic.SOURCE_PATH).read_bytes()
        compile(diagnostic.scene_source(current), '<actual-bound-scene>', 'exec')
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/bpy-runtime-acceptance.yml').read_text()
        block = workflow.split('- name: Capture the exact scene outside the sandbox as diagnostic evidence', 1)[1].split('- name: Prove both sandbox boundary', 1)[0]
        self.assertIn("failure() && inputs.app_artifact_id != '' && steps.native.outcome == 'failure'", block)
        self.assertIn('trap finish_control EXIT', block)
        self.assertIn('control-residual-processes.log', block)
        self.assertIn('codesign --verify --deep --strict', block)
        self.assertIn('-I -B -S scripts/bpy_metal_diagnostic.py', block)
        self.assertIn('--source-input', block)
        self.assertIn('control=$!', block)
        self.assertIn('wait "$control"', block)
        self.assertRegex(block, r'control-supervisor\.log" 2>&1 &\n\s*control=\$!\n\s*wait "\$control"\n\s*control=\n')
        self.assertRegex(block, r'control-source-fetch\.log" 2>&1 &\n(?:.*\n)*?\s*PY\n\s*control=\$!\n\s*wait "\$control"\n\s*control=\n')
        self.assertIn('kill -TERM "$control"', block)
        self.assertIn("trap 'cancel_control 130' INT", block)
        self.assertIn("trap 'cancel_control 143' TERM", block)
        self.assertIn('control-signature-before.log', block)
        self.assertIn('control-signature-before.log" 2>&1 || before=$?', block)
        self.assertIn('control-signature-before.status', block)
        finish = block.split('finish_control() {', 1)[1].split('cancel_control() {', 1)[0]
        self.assertIn('codesign --verify --deep --strict', finish)
        self.assertIn('control-signature-after.log" 2>&1 || result=1', finish)
        self.assertLess(block.index('control-signature-before.log'), block.index('-I -B -S scripts/bpy_metal_diagnostic.py'))
        self.assertNotIn('continue-on-error', block)
        self.assertEqual(diagnostic.group_rows(b'123 123 Z\n', 123), [dict(pid=123, pgid=123, state='Z')])
        for raw in (b'123 456 Z\n', b'1 123 Z\n', b'123 123 Z\n123 123 Z\n',
                    b'123 123 Z foreign-name\n', b'123 123 ?\n', b'x' * 65537,
                    b''.join(('%d 123 S\n' % pid).encode() for pid in range(123, 380))):
            with self.subTest(groupBytes=len(raw)), self.assertRaises(ValueError):
                diagnostic.group_rows(raw, 123)

    def test_success_requires_real_gpu_png_and_bound_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'outputs').mkdir()
            image = self.raster()
            (root / 'outputs/render.png').write_bytes(image)
            source, digest, executable = 'a' * 40, 'b' * 64, Path('/original/python3.13')
            bindings = dict(workerSHA256='c' * 64, nativeModule='/original/bpy/__init__.so', bpyModuleSHA256='d' * 64)
            receipt = self.result(executable, bindings, digest)
            supervision = self.supervision()
            def verdict(result=receipt, control=supervision):
                (root / 'result.json').write_text(json.dumps(result))
                return diagnostic.verdict(root, control, source, digest, executable, bindings)
            good = verdict()
            self.assertEqual(good['status'], 'gpuBranchCompletedDiagnosticOnly')
            self.assertEqual(good['childState'], 'completed')
            self.assertEqual([p['seconds'] for p in good['phaseDurations']], [1, 1, 1, 2])
            self.assertEqual(good['child']['devices'], receipt['devices'])
            self.assertEqual(verdict(dict(receipt, device='CPU'))['status'], 'cpuFallbackNotGPUProof')
            late = copy.deepcopy(receipt)
            late['phases'][-1]['monotonic'] = supervision['endedMonotonic'] + 1
            self.assertEqual(verdict(late)['status'], 'invalidReceipt')
            for key, value in [('scope', 'product-acceptance'), ('appSourceSHA', 'c' * 40), ('sceneSHA256', 'd' * 64),
                               ('pid', 456), ('executable', '/foreign/python'), ('state', 'loading'),
                               ('python', '3.12'), ('bpy', '5.3'), ('engine', 'BLENDER_EEVEE'), ('samples', 1),
                               ('workerSHA256', 'e' * 64), ('nativeModule', '/foreign/bpy.so'),
                               ('bpyModuleSHA256', 'f' * 64), ('computeDeviceType', 'NONE'), ('devices', [])]:
                with self.subTest(key=key):
                    self.assertEqual(verdict(dict(receipt, **{key: value}))['status'], 'invalidReceipt')
            ended = verdict(control=dict(supervision, timedOut=True))
            self.assertEqual(ended['status'], 'timedOutAfterCompletion')
            self.assertEqual(ended['childState'], 'completed')
            rendering = dict(receipt, state='rendering', phases=receipt['phases'][:3])
            self.assertEqual(verdict(rendering, dict(supervision, timedOut=True))['status'], 'timedOutDuringRender')
            failed = dict(receipt, state='failed', phases=receipt['phases'][:3] + [dict(state='failed', wall=1003, monotonic=103)])
            failure = verdict(failed, dict(supervision, timedOut=True))
            self.assertEqual(failure['status'], 'timedOutAfterFailure')
            self.assertEqual(failure['childState'], 'failed')
            self.assertEqual(diagnostic.exit_status(dict(failure, supervision=supervision)), 0)
            self.assertEqual(verdict(control=dict(supervision, exitCode=1))['status'], 'processFailedAfterCompletion')
            self.assertEqual(verdict(control=dict(supervision, reaped=False))['status'], 'processFailedAfterCompletion')
            self.assertEqual(diagnostic.exit_status(dict(status='timedOutDuringRender', supervision=supervision)), 0)
            self.assertEqual(diagnostic.exit_status(dict(status='processFailed', supervision=dict(supervision, reaped=False))), 1)
            self.assertEqual(diagnostic.exit_status(dict(status='processFailed', supervision=dict(supervision, cleanupErrors=['failure']))), 1)
            for changed in (self.raster(uniform=True), image[:33], image[:-1], image + b'trailing', image[:50] + b'changed' + image[57:]):
                with self.subTest(length=len(changed)):
                    (root / 'outputs/render.png').write_bytes(changed)
                    self.assertEqual(verdict()['status'], 'invalidImage')
            (root / 'outputs/render.png').write_bytes(image)
            with mock.patch.object(diagnostic, 'image_bytes', side_effect=diagnostic.ControlCancelled(15)), self.assertRaises(diagnostic.ControlCancelled):
                verdict()

    def test_owned_control_has_empty_stdin_sanitized_env_bounded_output_and_reaps_on_timeout(self):
        with tempfile.TemporaryDirectory() as folder, mock.patch.dict(os.environ,
                {'GH_TOKEN': 'fixture-token', 'PROVIDER_SECRET': 'fixture-secret', 'ANTHROPIC_API_KEY': 'fixture-api'}):
            base = Path(folder)
            environment = diagnostic.environment(base)
            self.assertEqual(set(environment), {'HOME', 'TMPDIR', 'LANG', 'BLENDER_USER_CONFIG', 'BLENDER_USER_SCRIPTS', 'BLENDER_USER_DATAFILES'})
            popen, killpg, select = subprocess.Popen, os.killpg, diagnostic.selectors.DefaultSelector.select
            original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            snapshot_root = base / 'group-inspection'
            snapshot_root.mkdir()
            child = popen([sys.executable, '-I', '-c', 'pass'], stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, env=environment)
            try:
                deadline = time.monotonic() + 5
                while not diagnostic.leader_exited(child.pid) and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(diagnostic.leader_exited(child.pid))
                rows = diagnostic.group_snapshot(child.pid, snapshot_root)
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]['pid'], child.pid)
                self.assertTrue(rows[0]['state'].startswith('Z'))
                inspection = json.loads((snapshot_root / 'group-inventory.json').read_text())
                self.assertNotIn('-A', inspection['command'])
                self.assertEqual(inspection['command'], ['/bin/ps', '-s', str(child.pid), '-o', 'pid=,pgid=,state='])
            finally:
                killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
            grandchild_code = "import os,subprocess,sys;from pathlib import Path;p=subprocess.Popen([sys.executable,'-I','-c','import time;time.sleep(30)'],stdin=subprocess.DEVNULL);Path('grandchild.part').write_text(str(p.pid));os.replace('grandchild.part','grandchild.pid');print('grandchild-ready',flush=True)"
            cases = [
                ('output', "import os,sys;assert sys.stdin.buffer.read()==b'';assert all(k not in os.environ for k in ['GH_TOKEN','PROVIDER_SECRET','ANTHROPIC_API_KEY']);sys.stdout.buffer.write(b'x'*(5*1024*1024))", 5),
                ('timeout', 'import time;time.sleep(30)', .15),
                ('cancel', 'import time;time.sleep(30)', 5),
                ('real-signal', 'import time;time.sleep(30)', 5),
                ('liveness-interrupt', 'pass', 5),
                ('selector-start', 'import time;time.sleep(30)', 5),
                ('reap-failure', 'import time;time.sleep(30)', .15),
                ('zombie-permission', 'pass', 5),
                ('grandchild', grandchild_code, 2),
                ('grandchild-permission', grandchild_code, 2)]
            for name, code, timeout in cases:
                root = base / name
                root.mkdir()
                created, signals, grandchild = [], [], {}
                def start(*args, **kwargs):
                    self.assertTrue({signal.SIGINT, signal.SIGTERM}.issubset(signal.pthread_sigmask(signal.SIG_BLOCK, set())))
                    child = popen(*args, **kwargs)
                    created.append(child)
                    self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
                    self.assertTrue(kwargs['start_new_session'])
                    return child
                def send_group(pid, sig):
                    self.assertTrue({signal.SIGINT, signal.SIGTERM}.issubset(signal.pthread_sigmask(signal.SIG_BLOCK, set())))
                    signals.append((pid, sig))
                    if name == 'grandchild-permission':
                        raise PermissionError('fixture live group denied')
                    value = killpg(pid, sig)
                    if name == 'zombie-permission':
                        raise PermissionError('fixture zombie group denied')
                    return value
                def snapshot(pid, output):
                    self.assertEqual(pid, created[0].pid)
                    self.assertEqual(output, root)
                    self.assertTrue(diagnostic.leader_exited(pid))
                    rows = [dict(pid=pid, pgid=pid, state='Z')]
                    if name == 'grandchild-permission':
                        os.kill(grandchild['pid'], 0)
                        self.assertEqual(os.getpgid(grandchild['pid']), pid)
                        rows.append(dict(pid=grandchild['pid'], pgid=pid, state='S'))
                    return rows
                def observe(selector, wait):
                    events = select(selector, wait)
                    marker = root / 'grandchild.pid'
                    if marker.exists() and not grandchild:
                        pid = int(marker.read_text())
                        grandchild.update(pid=pid, fd=os.pidfd_open(pid))
                    return events
                try:
                    with mock.patch.object(diagnostic.subprocess, 'Popen', side_effect=start), \
                         mock.patch.object(diagnostic.os, 'killpg', side_effect=send_group), \
                         mock.patch.object(diagnostic, 'group_snapshot', side_effect=snapshot) as group_snapshot, \
                         mock.patch.object(popen, 'poll', side_effect=AssertionError('leader must stay unreaped')):
                        if name == 'cancel':
                            error = KeyboardInterrupt
                            with mock.patch.object(diagnostic.selectors.DefaultSelector, 'select', side_effect=error), self.assertRaises(error):
                                diagnostic.run_bounded([sys.executable, '-I', '-c', code], environment, root, root / 'process.log', timeout)
                        elif name == 'real-signal':
                            previous = signal.signal(signal.SIGTERM, diagnostic.cancel)
                            thread_id = threading.get_ident()
                            timer = threading.Timer(.5, lambda: signal.pthread_kill(thread_id, signal.SIGTERM))
                            started = time.monotonic()
                            try:
                                timer.start()
                                with self.assertRaises(diagnostic.ControlCancelled):
                                    diagnostic.run_bounded([sys.executable, '-I', '-c', code], environment, root, root / 'process.log', timeout)
                                self.assertLess(time.monotonic() - started, 2)
                            finally:
                                timer.cancel()
                                timer.join(timeout=2)
                                signal.signal(signal.SIGTERM, previous)
                        elif name == 'liveness-interrupt':
                            with mock.patch.object(diagnostic.os, 'waitid', side_effect=diagnostic.ControlCancelled(15)), self.assertRaises(diagnostic.ControlCancelled):
                                diagnostic.run_bounded([sys.executable, '-I', '-c', code], environment, root, root / 'process.log', timeout)
                        elif name == 'selector-start':
                            with mock.patch.object(diagnostic.selectors, 'DefaultSelector', side_effect=RuntimeError), self.assertRaises(RuntimeError):
                                diagnostic.run_bounded([sys.executable, '-I', '-c', code], environment, root, root / 'process.log', timeout)
                        elif name == 'reap-failure':
                            with mock.patch.object(popen, 'wait', side_effect=subprocess.TimeoutExpired('fixture', 5)), self.assertRaises(subprocess.TimeoutExpired):
                                diagnostic.run_bounded([sys.executable, '-I', '-c', code], environment, root, root / 'process.log', timeout)
                        elif name == 'grandchild-permission':
                            with mock.patch.object(diagnostic.selectors.DefaultSelector, 'select', observe), self.assertRaises(RuntimeError):
                                diagnostic.run_bounded([sys.executable, '-I', '-c', code], environment, root, root / 'process.log', timeout)
                            self.assertIn('fd', grandchild)
                            os.kill(grandchild['pid'], 0)
                        elif name == 'grandchild':
                            with mock.patch.object(diagnostic.selectors.DefaultSelector, 'select', observe):
                                result = diagnostic.run_bounded([sys.executable, '-I', '-c', code], environment, root, root / 'process.log', timeout)
                            self.assertTrue(result['timedOut'])
                            self.assertEqual(result['exitCode'], 0)
                            self.assertIn('fd', grandchild)
                            deadline = time.monotonic() + 5
                            while time.monotonic() < deadline:
                                try:
                                    os.kill(grandchild['pid'], 0)
                                except ProcessLookupError:
                                    break
                                time.sleep(.01)
                            with self.assertRaises(ProcessLookupError):
                                os.kill(grandchild['pid'], 0)
                        else:
                            result = diagnostic.run_bounded([sys.executable, '-I', '-c', code], environment, root, root / 'process.log', timeout)
                            self.assertEqual(result['timedOut'], name == 'timeout')
                            if name == 'output':
                                self.assertEqual(result['exitCode'], 0)
                                self.assertEqual(result['bytes'], 4 * 1024 * 1024)
                                self.assertEqual(result['discardedBytes'], 1024 * 1024)
                            if name == 'zombie-permission':
                                self.assertEqual(result['groupKill'], 'zombieOnly')
                                self.assertEqual(result['cleanupErrors'], [])
                                self.assertEqual(diagnostic.exit_status(dict(status='gpuBranchCompletedDiagnosticOnly', supervision=result)), 0)
                        if name in ('zombie-permission', 'grandchild-permission'):
                            group_snapshot.assert_called_once()
                        else:
                            group_snapshot.assert_not_called()
                    self.assertEqual(len(created), 1)
                    self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, set()), original_mask)
                    self.assertIn((created[0].pid, signal.SIGKILL), signals)
                    supervision = json.loads((root / 'supervision.json').read_text())
                    self.assertEqual(supervision['reaped'], name != 'reap-failure')
                    if name == 'reap-failure':
                        self.assertEqual(diagnostic.exit_status(dict(status='processFailed', supervision=supervision)), 1)
                    if name == 'grandchild-permission':
                        self.assertEqual(supervision['groupKill'], 'failed')
                        self.assertTrue(supervision['cleanupErrors'])
                        self.assertEqual(diagnostic.exit_status(dict(status='processFailed', supervision=supervision)), 1)
                finally:
                    if 'fd' in grandchild:
                        try:
                            signal.pidfd_send_signal(grandchild['fd'], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        os.close(grandchild['fd'])
                    for child in created:
                        if child.poll() is None:
                            child.kill()
                        child.wait(timeout=5)
            raw = self.raw_scene
            blob = hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
            for mutate in (False, True):
                fixture = base / ('mutated-app' if mutate else 'bound-app')
                fixture.mkdir()
                app, executable, worker, module = self.fake_app(fixture)
                output = fixture / 'evidence/control'
                source_input = fixture / 'original-source.json'
                with mock.patch.object(diagnostic, 'original_source', return_value=(raw, blob)):
                    diagnostic.prefetch_source('a' * 40, source_input)
                seen = {}
                def run(command, env, root, log):
                    config = json.loads((root / 'control.json').read_text())
                    self.assertEqual(command, [str(executable), '-I', '-B', '-S', str(root / 'control.py'), str(root / 'control.json')])
                    scratch = Path(env['HOME']).parent
                    self.assertEqual(env, diagnostic.environment(scratch))
                    self.assertTrue(all(not Path(value).is_relative_to(output) for key, value in env.items() if key != 'LANG'))
                    for index in range(300):
                        (scratch / 'tmp' / str(index)).write_bytes(b'cache')
                    seen['scratch'] = scratch
                    bindings = {k: config[k] for k in ('workerSHA256', 'nativeModule', 'bpyModuleSHA256')}
                    result = self.result(executable, bindings, config['sceneSHA256'])
                    (root / 'result.json').write_text(json.dumps(result))
                    (root / 'outputs/render.png').write_bytes(self.raster())
                    supervision = self.supervision()
                    (root / 'supervision.json').write_text(json.dumps(supervision))
                    if mutate:
                        worker.write_bytes(b'changed fixture worker')
                    return supervision
                with mock.patch.object(diagnostic, 'run_bounded', side_effect=run):
                    result = diagnostic.collect(app, output, 'a' * 40, source_input)
                self.assertEqual(diagnostic.exit_status(result), int(mutate))
                if mutate:
                    self.assertIn('original runtime bytes or inventory changed', result['errorMessage'])
                else:
                    self.assertEqual(result['status'], 'gpuBranchCompletedDiagnosticOnly')
                    self.assertTrue(result['runtimeUnchanged'])
                    self.assertEqual(result['workerSHA256'], hashlib.sha256(worker.read_bytes()).hexdigest())
                    self.assertEqual(result['bpyModuleSHA256'], hashlib.sha256(module.read_bytes()).hexdigest())
                self.assertTrue(result['scratchInventory']['capped'])
                self.assertLessEqual(result['scratchInventory']['observedEntries'], 256)
                self.assertTrue(result['scratchRemoved'])
                self.assertFalse(seen['scratch'].exists())
                text = ' '.join(result['differences'])
                for term in ('RLIMIT', 'APFS', 'warm-probe', 'descriptor', 'pycache', 'save_as_mainfile', 'Metal cache'):
                    self.assertIn(term, text)


if __name__ == '__main__':
    unittest.main()
