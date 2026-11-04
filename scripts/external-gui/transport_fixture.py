"""Retain the exact project from a completed normal journey without rerunning its actions."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile
import zipfile

import acceptance as journey
import test_bundle
from transport import fixture_identity, project_files


def require(condition, message):
    journey.require(condition, message)


def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=False)
    seen = set()
    with zipfile.ZipFile(archive) as bundle:
        require(sum(item.file_size for item in bundle.infolist()) <= 2_000_000_000, 'Journey evidence exceeds its bound')
        for item in bundle.infolist():
            name = item.filename.rstrip('/')
            path = PurePosixPath(name)
            require(name and not path.is_absolute() and '..' not in path.parts and '\\' not in name
                    and str(path) == name and name not in seen, 'Noncanonical journey archive member')
            seen.add(name)
            kind = stat.S_IFMT(item.external_attr >> 16)
            require(kind in (0, stat.S_IFDIR, stat.S_IFREG), 'Journey archive cannot introduce links or devices')
            target = destination / name
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(item) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
            mode = stat.S_IMODE(item.external_attr >> 16)
            if mode:
                target.chmod(mode)


def prepare(args):
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo',
            'Prepare original journey fixtures only in this repository CI')
    run = test_bundle.api('/actions/runs/' + str(args.run_id))
    job = test_bundle.api('/actions/jobs/' + str(args.job_id))
    artifact = test_bundle.api('/actions/artifacts/' + str(args.artifact_id))
    require(run.get('head_sha') == args.source_sha and run.get('run_attempt') == 1
            and run.get('path') == '.github/workflows/release.yml' and run.get('actor', {}).get('login') == 'iret77'
            and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo', 'Journey belongs to another product run')
    require(job.get('run_id') == args.run_id and job.get('head_sha') == args.source_sha and job.get('run_attempt') == 1
            and job.get('name') == 'external-user-acceptance / Normal app at 1 text size'
            and job.get('labels') == ['macrunner'] and job.get('status') == 'completed' and job.get('conclusion') == 'success',
            'Only the completed actual normal DMG journey can supply a project')
    require(artifact.get('id') == args.artifact_id and artifact.get('name') == 'external-gui-dmg-1-1'
            and artifact.get('expired') is False and artifact.get('digest') == 'sha256:' + args.artifact_sha256
            and artifact.get('workflow_run', {}).get('id') == args.run_id
            and artifact.get('workflow_run', {}).get('head_sha') == args.source_sha, 'Original journey artifact differs')
    work = Path(tempfile.mkdtemp(prefix='ngv-passed-journey-'))
    archive = work / 'original.zip'
    test_bundle.download(artifact, archive)
    require(archive.stat().st_size == artifact['size_in_bytes'], 'Incomplete original journey archive')
    evidence = work / 'evidence'
    extract(archive, evidence)
    validator = work / 'original-validator'
    journey.command(['git', '-C', journey.REPOSITORY, 'worktree', 'add', '--detach', validator, args.source_sha], work / 'validator.log')
    journey.command(['python3', validator / 'scripts/external-gui/acceptance.py', 'validate', '--source-sha', args.source_sha,
                     '--evidence', evidence, '--scale', '1', '--dmg-sha256', args.dmg_sha256], work / 'validator.log', timeout=180)
    result = journey.read_json(evidence / 'result.json')
    identity = journey.read_json(evidence / 'identity.json')
    require(result.get('completed') is True and result.get('dmgSHA256') == args.dmg_sha256
            and identity.get('app', {}).get('NGVSourceCommit') == args.source_sha
            and identity.get('runID') == str(args.run_id) and identity.get('runAttempt') == '1',
            'Completed journey result lost its original execution binding')
    source_sha = result['export']['sourceSHA256']
    original = evidence / 'External GUI.ngv'
    require(original.is_dir() and not original.is_symlink(), 'Completed journey did not retain its real project')
    candidates = [path for path in original.rglob('*') if path.is_file() and not path.is_symlink() and journey.sha256(path) == source_sha]
    require(len(candidates) == 1, 'The original imported media is missing or ambiguous inside the project')
    source = candidates[0]
    probe = json.loads(journey.output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', source]))
    videos = [stream for stream in probe['streams'] if stream.get('codec_type') == 'video']
    require(len(videos) == 1 and videos[0].get('nb_frames') == '120' and videos[0].get('r_frame_rate') == '30/1'
            and videos[0].get('width') == 320 and videos[0].get('height') == 180
            and abs(float(probe['format']['duration']) - 4) < .000001, 'Actual source media does not prove the fixed endpoint oracle')
    fixture = {'schema': 'nexgenvideo/transport-fixture/1', 'sourceSHA': args.source_sha, 'dmgSHA256': args.dmg_sha256,
               'journeyRunID': args.run_id, 'journeyJobID': args.job_id, 'journeyArtifactID': args.artifact_id,
               'journeyArtifactSHA256': args.artifact_sha256, 'journeyResultSHA256': journey.sha256(evidence / 'result.json'),
               'journeyIdentitySHA256': journey.sha256(evidence / 'identity.json'),
               'appTreeSHA256': identity['app']['treeSHA256'], 'projectFiles': project_files(original),
               'projectTreeSHA256': journey.tree_sha256(original), 'sourceSHA256': source_sha,
               'sourceRelativePath': source.relative_to(original).as_posix(), 'fps': 30, 'endFrame': 120, 'sourceFrames': 120}
    fixture_identity(original, source, fixture)
    output = Path(args.output); output.mkdir(parents=True, exist_ok=False)
    shutil.copytree(original, output / 'External GUI.ngv', symlinks=True)
    shutil.copy2(work / 'validator.log', output / 'original-journey-validation.log')
    journey.write_json(output / 'source-ffprobe.json', probe)
    journey.write_json(output / 'fixture.json', fixture)
    require(journey.tree_sha256(output / 'External GUI.ngv') == fixture['projectTreeSHA256'], 'Fixture transfer changed project bytes')
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as handle:
        handle.write('fixture_sha256=' + journey.sha256(output / 'fixture.json') + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--run-id', required=True, type=int)
    parser.add_argument('--job-id', required=True, type=int)
    parser.add_argument('--artifact-id', required=True, type=int)
    parser.add_argument('--artifact-sha256', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--dmg-sha256', required=True)
    parser.add_argument('--output', required=True)
    prepare(parser.parse_args())


if __name__ == '__main__':
    main()
