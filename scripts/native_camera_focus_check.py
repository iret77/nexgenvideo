"""Run the selected native input regression on the linked test bundle."""
import json
import os
from pathlib import Path

import app_cohort_v2
import native_app_build_plan as capture
from native_app_target_build import native_guard
import release_test_repair as retained
from retained_app_test_products import require, write


def verify_input(root):
    from isolated_test_home import environment as isolated_environment
    from native_app_failure_diagnostic import measure, run_owned, scope_filter
    from run_macos_tests import app_environment, framework_output, host_receipt

    runner = native_guard(root)
    prepared = json.loads((root / 'prepared.json').read_bytes())
    value = app_cohort_v2.verify_context(prepared['cohortV2'], current=True)
    require(int(value['build']) >= 129, 'Unexpected native input regression cohort')
    product = json.loads((root / 'tests/product-receipt.json').read_bytes())
    plan = prepared['plans']['tests']
    link, = [row for row in plan['operations']['links'] if row['targetGUID'] == plan['driver']['targetGUID']]
    image = Path(link['output'])
    arena = Path(plan['operations']['arena'])
    runtime = arena / 'Products/Release'
    host = runtime / 'NexGenVideoAppKitTestHost'
    image_sha = capture.sha(image)
    require(product['sourceSHA'] == prepared['sourceSHA'] == os.environ['GITHUB_SHA']
            and product['state']['linkComplete'] and product['state']['linkedOutput'] == str(image)
            and image.parents[3] == runtime and product['files'][image.relative_to(arena).as_posix()]['sha256'] == image_sha
            and capture.sha(host) == retained.HOST_SHA, 'Native test host or current test bundle differs')
    if value['build'] == '129':
        method = 'canonicalNativeAccessibilityHitKeepsSystemInputAndRealFieldFocus()'
        directory = 'camera-focus'
    else:
        method = 'canonicalNativeAccessibilityIdentityAndGeometryAreRevalidatedBeforeDown()'
        directory = 'window-presentation'
    method = 'NexGenVideoTests.NativePointerInteractionTests/' + method
    identity, = [name for name in app_cohort_v2.criteria()['modules']['app']['exactEndedFunctionIDs']
                 if name.rsplit('/', 1)[0] == method]
    output = root / directory
    output.mkdir()
    base = {key: os.environ[key] for key in ('PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'GITHUB_SHA') if key in os.environ}
    env = isolated_environment(base, runner / (directory + '-home'), output / 'home.json')
    env = app_environment(env, runtime, image, output)
    env.update(NGV_APPKIT_TEST_BUNDLE=str(image), NGV_APPKIT_TEST_EVENTS=str(output / 'events.jsonl'),
               NGV_APPKIT_TEST_RECEIPT=str(output / 'host-receipt.json'), NGV_APPKIT_EXCEPTION_EVIDENCE=str(output / 'exception.jsonl'))
    command = [str(host), '--event-stream-version', '0', '--no-parallel', '--filter', scope_filter([identity])]
    process = run_owned(command, output / 'console.log', env)
    require(process['exitCode'] == 0 and process['processReaped'] and process['eof'] and not process['stoppedReason'],
            'Native input regression failed on the linked test bundle')
    events = measure((output / 'events.jsonl').read_bytes(), [identity], expected_cases={})
    require(events['passed'], 'Native input test recorded an issue')
    host_receipt(output / 'host-receipt.json', {'recordCount': events['records']}, pid=process['pid'],
                 bundle=image, host=host, source_sha=prepared['sourceSHA'])
    framework_output(output / 'console.log', 1, 0)
    write(output / 'verified.json', {'source': prepared['sourceSHA'], 'method': identity, 'testSHA256': image_sha,
                                     'hostSHA256': retained.HOST_SHA, 'processID': process['pid']})


if __name__ == '__main__':
    verify_input(Path(os.environ['RUNNER_TEMP']).resolve() / 'app-target-build')
