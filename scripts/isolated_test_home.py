"""Configure an owned temporary home for a test process and its children."""
import argparse
import json
import os
from pathlib import Path
import pwd
import tempfile


def environment(parent, home_path, evidence=None):
    home_path = Path(home_path)
    if home_path.is_symlink():
        raise ValueError('The test home must not be a symlink')
    home_path = home_path.resolve()
    real_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    if real_home.is_relative_to(home_path):
        raise ValueError('The test home must be separate from the account home')
    home_path.mkdir(parents=True, mode=0o700, exist_ok=True)
    result = dict(parent, HOME=str(home_path), CFFIXED_USER_HOME=str(home_path))
    if evidence is not None:
        Path(evidence).write_text(json.dumps({
            'schema': 'nexgenvideo/isolated-test-home/1',
            'HOME': result['HOME'], 'CFFIXED_USER_HOME': result['CFFIXED_USER_HOME'],
            'accountHomeExcluded': True,
        }, indent=2, sort_keys=True) + '\n')
    return result


def process_environment(parent, evidence):
    home_path = parent.get('CFFIXED_USER_HOME')
    if not home_path:
        home_path = tempfile.mkdtemp(prefix='nexgenvideo-test-home-', dir=parent.get('RUNNER_TEMP'))
    return environment(parent, home_path, evidence)


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('A test command is required')
    child = environment(os.environ, args.home, args.evidence)
    os.execvpe(command[0], command, child)


if __name__ == '__main__':
    main()
