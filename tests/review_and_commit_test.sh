#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$script_dir/review_and_commit.sh" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix='review-and-commit-test-') as directory:
    root = Path(directory)
    scripts = root / 'script directory'
    scripts.mkdir()
    wrapper = scripts / 'review_and_commit.sh'
    shutil.copyfile(sys.argv[1], wrapper)
    for stage, filename in [('review', 'review_untill_satisfied.sh'), ('commit', 'commit_by_codex.sh')]:
        (scripts / filename).write_text(r'''#!/usr/bin/env bash
python3 - "$@" <<'MOCK'
import json, os, sys
from pathlib import Path
stage = STAGE
with open(os.environ['CALL_LOG'], 'a') as stream:
    stream.write(json.dumps([stage, sys.argv[1:]]) + '\n')
if stage == 'review':
    result = Path(os.environ['REVIEW_UNTIL_RESULT_FILE'])
    Path(os.environ['RESULT_LOCATION']).write_text(str(result))
    mode = os.environ.get('RESULT_MODE', 'valid')
    repo = os.environ['REVIEW_REPO'].encode()
    payloads = {'valid': repo + b'\0', 'empty': b'', 'unterminated': repo,
                'extra': repo + b'\0extra', 'double': repo + b'\0\0',
                'relative': b'repo\0', 'nonrepo': os.environ['NON_REPO'].encode() + b'\0',
                'nested': repo + b'/nested\0'}
    if mode != 'missing':
        result.write_bytes(payloads[mode])
else:
    assert 'REVIEW_UNTIL_RESULT_FILE' not in os.environ
sys.exit(int(os.environ.get(stage.upper() + '_STATUS', '0')))
MOCK
'''.replace('STAGE', repr(stage)))
    repo = root / 'target repo'
    repo.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.pop('REVIEW_UNTIL_RESULT_FILE', None)
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', CALL_LOG=str(root / 'calls'),
               REVIEW_REPO=str(repo), NON_REPO=str(root), RESULT_LOCATION=str(root / 'result-location'))
    subprocess.run(['git', 'init', '-q', str(repo)], env=env, check=True)
    nested = repo / 'nested'
    nested.mkdir()

    def run(options=(), cwd=nested, **statuses):
        log = Path(env['CALL_LOG'])
        log.write_text('')
        location = Path(env['RESULT_LOCATION'])
        location.unlink(missing_ok=True)
        result = subprocess.run(['bash', str(wrapper), *options], cwd=cwd,
                                env=dict(env, **statuses), stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=10)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        if location.exists():
            assert not Path(location.read_text()).parent.exists(), 'Result directory leaked'
        return result, calls

    result, calls = run()
    assert result.returncode == 0, result.stderr
    assert calls == [['review', []], ['commit', ['--repo', str(repo), '-y']]], calls

    options = ['--repo', 'target repo/nested', '--max-loops', '3', '--log-dir', 'review logs',
               '--fast', '--model', 'example-model']
    result, calls = run(options, cwd=root)
    assert result.returncode == 0, result.stderr
    assert calls == [
        ['review', options[:-2]],
        ['commit', ['--repo', str(repo), '--model', 'example-model', '-y']]], calls

    for status in ('1', '2', '124', '130', '143'):
        result, calls = run(REVIEW_STATUS=status)
        assert result.returncode == int(status) and len(calls) == 1, (result, calls)
    result, calls = run(COMMIT_STATUS='7')
    assert result.returncode == 7 and len(calls) == 2

    for option in ('--model',):
        for tail in ([], [''], ['--fast']):
            result, calls = run([option, *tail])
            assert result.returncode == 2 and not calls, (option, tail, result)
    for options in (['--resume'], ['--resume', 'logs/original run.log'],
                    ['--resume=logs/original run.log'],
                    ['--repo', 'target repo', '--resume', '--allow-worktree-changes', '--max-loops', '15']):
        result, calls = run(options, cwd=root)
        assert result.returncode == 0, result.stderr
        assert calls == [['review', options], ['commit', ['--repo', str(repo), '-y']]], calls
    # New options need no wrapper changes; rejection belongs to the child.
    for options in (['--future-option', 'some value'], ['--unknown'], ['-y'], ['--repo']):
        result, calls = run(options, REVIEW_STATUS='2')
        assert result.returncode == 2 and calls == [['review', options]], calls
    for mode in ('missing', 'empty', 'unterminated', 'extra', 'double', 'relative', 'nonrepo', 'nested'):
        result, calls = run(RESULT_MODE=mode)
        assert result.returncode == 2 and len(calls) == 1, (mode, result, calls)
    for option in ('-h', '--help'):
        result, calls = run([option], cwd=root)
        assert result.returncode == 0 and b'--model' in result.stdout and not calls
    print('review_and_commit tests passed')
PY
