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
stage = STAGE
with open(os.environ['CALL_LOG'], 'a') as stream:
    stream.write(json.dumps([stage, sys.argv[1:]]) + '\n')
sys.exit(int(os.environ.get(stage.upper() + '_STATUS', '0')))
MOCK
'''.replace('STAGE', repr(stage)))
    repo = root / 'target repo'
    repo.mkdir()
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', CALL_LOG=str(root / 'calls'))
    subprocess.run(['git', 'init', '-q', str(repo)], env=env, check=True)
    nested = repo / 'nested'
    nested.mkdir()

    def run(options=(), cwd=nested, **statuses):
        log = Path(env['CALL_LOG'])
        log.write_text('')
        result = subprocess.run(['bash', str(wrapper), *options], cwd=cwd,
                                env=dict(env, **statuses), stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=10)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls

    result, calls = run()
    assert result.returncode == 0, result.stderr
    assert calls == [['review', ['--repo', str(repo)]], ['commit', ['--repo', str(repo), '-y']]], calls

    options = ['--repo', 'target repo/nested', '--max-loops', '3', '--log-dir', 'review logs',
               '--fast', '--model', 'example-model']
    result, calls = run(options, cwd=root)
    assert result.returncode == 0, result.stderr
    assert calls == [
        ['review', ['--repo', str(repo), '--max-loops', '3', '--log-dir', 'review logs', '--fast']],
        ['commit', ['--repo', str(repo), '--model', 'example-model', '-y']]], calls

    for status in ('1', '2', '124', '130', '143'):
        result, calls = run(REVIEW_STATUS=status)
        assert result.returncode == int(status) and len(calls) == 1, (result, calls)
    result, calls = run(COMMIT_STATUS='7')
    assert result.returncode == 7 and len(calls) == 2

    for option in ('--repo', '--max-loops', '--log-dir', '--model'):
        for tail in ([], [''], ['--fast']):
            result, calls = run([option, *tail])
            assert result.returncode == 2 and not calls, (option, tail, result)
    for option in ('--unknown', '--resume', '-y'):
        result, calls = run([option])
        assert result.returncode == 2 and not calls
    result, calls = run(['--repo', str(root)])
    assert result.returncode == 2 and not calls
    for option in ('-h', '--help'):
        result, calls = run([option], cwd=root)
        assert result.returncode == 0 and b'--model' in result.stdout and not calls
    print('review_and_commit tests passed')
PY
