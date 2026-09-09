#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$script_dir/commit_by_codex.sh" <<'PY'
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time

script = sys.argv[1]
message = 'Describe mixed changes $(touch should-not-exist) `literal`\n\nKeep "quotes" and a second paragraph.'
with tempfile.TemporaryDirectory(prefix='commit-by-codex-test-') as directory:
    root = Path(directory)
    binary = root / 'bin'
    binary.mkdir()
    mock = binary / 'codex'
    mock.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
assert args[0] == "exec"
assert args[args.index("--sandbox") + 1] == "read-only"
assert args[args.index("--model") + 1] == os.environ.get("EXPECTED_MODEL", "gpt-5.3-codex-spark")
assert "--ephemeral" in args and "--json" in args
prompt = sys.stdin.read()
assert "AGENTS.md" in prompt and "AGENTS.override.md" in prompt
assert "Full textual candidate diff:" in prompt
pathlib.Path(os.environ["PROMPT_CAPTURE"]).write_text(prompt)
mode = os.environ.get("MOCK_MODE", "success")
if mode == "worktree": pathlib.Path("tracked").write_text("changed during generation")
if mode == "index": subprocess.run(["git", "add", "tracked"], check=True)
if mode == "head": subprocess.run(["git", "commit", "--allow-empty", "-m", "Concurrent commit"], check=True, stdout=sys.stderr)
if mode == "branch": subprocess.run(["git", "checkout", "-b", "other"], check=True, stdout=sys.stderr)
if mode == "fail": sys.exit(7)
if mode == "malformed":
    print("not JSON")
    sys.exit(0)
message = os.environ["TEST_MESSAGE"] if mode != "empty" else ""
result = {"ready": mode != "blocked", "message": message}
print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(result)}}))
print(json.dumps({"type": "turn.completed"}))
''')
    mock.chmod(0o755)
    env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_AUTHOR_NAME='Test Author', GIT_AUTHOR_EMAIL='author@example.com',
               GIT_COMMITTER_NAME='Test Author', GIT_COMMITTER_EMAIL='author@example.com',
               TEST_MESSAGE=message, PROMPT_CAPTURE=str(root / 'prompt'))
    # The tests always operate on isolated repositories and a mock model.
    for key in list(env):
        if key.startswith('GIT_') and key not in {
            'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_AUTHOR_NAME',
            'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL'}:
            del env[key]

    def git(repo, *args):
        return subprocess.check_output(['git', '-C', str(repo), *args], env=env, stderr=subprocess.PIPE)

    def setup(name, unborn=False):
        repo = root / name
        repo.mkdir()
        git(repo, 'init', '-q')
        (repo / 'tracked').write_text('initial\n')
        (repo / 'deleted').write_text('remove me\n')
        git(repo, 'add', '.')
        if not unborn:
            git(repo, 'commit', '-qm', 'Initial commit')
        (repo / 'tracked').write_text('staged\n')
        git(repo, 'add', 'tracked')
        (repo / 'tracked').write_text('unstaged\n')
        (repo / 'deleted').unlink()
        (repo / 'new file\nwith newline').write_text('new content\n')
        (repo / '.gitignore').write_text('ignored\n')
        (repo / 'ignored').write_text('not a candidate\n')
        (repo / 'AGENTS.md').write_text('Use concise commit messages.\n')
        return repo

    def index_bytes(repo):
        p = repo / '.git/index'
        return p.read_bytes() if p.exists() else None

    def run(repo, answer='y', mode='success', at_prompt=None, options=(), interrupt=False):
        master, slave = pty.openpty()
        before_tmp = set(Path('/tmp').glob('commit-by-codex.*'))
        process = subprocess.Popen(['bash', script, '--repo', str(repo), *options],
                                   stdin=slave, stdout=slave, stderr=slave,
                                   env=dict(env, MOCK_MODE=mode, EXPECTED_MODEL=options[1] if options else "gpt-5.3-codex-spark"), start_new_session=True)
        os.close(slave)
        output = bytearray()
        answered = False
        deadline = time.monotonic() + 20
        try:
            while True:
                if time.monotonic() > deadline:
                    raise AssertionError('Timed out: ' + output.decode(errors='replace'))
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data: break
                    output.extend(data)
                if b'Commit these changes? [y/N]' in output and not answered:
                    answered = True
                    if at_prompt: at_prompt()
                    if interrupt:
                        os.killpg(process.pid, signal.SIGINT)
                    else:
                        os.write(master, (answer + '\n').encode())
                if process.poll() is not None and not ready:
                    break
            code = process.wait(timeout=5)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)
        assert set(Path('/tmp').glob('commit-by-codex.*')) <= before_tmp, 'Leaked temporary directory'
        assert not (repo / '.git/index.lock').exists(), 'Leaked real index lock'
        return code, output.decode(errors='replace')

    for unborn in (False, True):
        repo = setup('success-' + str(unborn), unborn)
        code, output = run(repo)
        assert code == 0, output
        assert git(repo, 'log', '-1', '--format=%B').decode().rstrip('\n') == message
        assert git(repo, 'status', '--porcelain') == b''
        assert git(repo, 'show', 'HEAD:tracked') == b'unstaged\n'
        assert not (repo / 'should-not-exist').exists()
        prompt = (root / 'prompt').read_text()
        assert '+new content' in prompt and '+unstaged' in prompt
        if not unborn: assert '-remove me' in prompt
        assert 'not a candidate' not in prompt

    for mode in ('cancel', 'default', 'interrupt', 'fail', 'malformed', 'empty', 'blocked', 'worktree', 'index', 'head', 'branch'):
        repo = setup(mode)
        before = index_bytes(repo)
        head = git(repo, 'rev-parse', 'HEAD')
        code, output = run(repo, answer='n' if mode == 'cancel' else '' if mode == 'default' else 'y',
                           mode='success' if mode in ('cancel', 'default', 'interrupt') else mode,
                           interrupt=mode == 'interrupt')
        assert code == 0 if mode in ('cancel', 'default') else code != 0, output
        if mode not in ('index', 'head', 'branch'): assert index_bytes(repo) == before, mode
        if mode != 'head': assert git(repo, 'rev-parse', 'HEAD') == head, mode

    for change in ('worktree', 'index', 'head', 'branch', 'new', 'permission'):
        repo = setup('confirm-' + change)
        head = git(repo, 'rev-parse', 'HEAD')
        def mutate():
            if change == 'worktree': (repo / 'tracked').write_text('changed after display')
            elif change == 'index': git(repo, 'add', 'tracked')
            elif change == 'head': git(repo, 'commit', '--allow-empty', '-m', 'Concurrent commit')
            elif change == 'branch': git(repo, 'checkout', '-b', 'other')
            elif change == 'new': (repo / 'later').write_text('new after display')
            elif change == 'permission': (repo / 'tracked').chmod(0o755)
        code, output = run(repo, at_prompt=mutate)
        assert code != 0 and 'changed' in output, output
        if change != 'head': assert git(repo, 'rev-parse', 'HEAD') == head

    repo = setup('mtime')
    code, output = run(repo, at_prompt=lambda: os.utime(repo / 'tracked', None))
    assert code == 0, output

    repo = setup('hook-failure')
    hook = repo / '.git/hooks/pre-commit'
    hook.write_text('#!/bin/sh\nexit 1\n')
    hook.chmod(0o755)
    before = index_bytes(repo)
    head = git(repo, 'rev-parse', 'HEAD')
    code, output = run(repo)
    assert code != 0 and 'Git commit failed' in output, output
    assert index_bytes(repo) == before and git(repo, 'rev-parse', 'HEAD') == head

    repo = setup('late-worktree')
    hook = repo / '.git/hooks/pre-commit'
    hook.write_text('#!/bin/sh\nprintf "later change" > tracked\n')
    hook.chmod(0o755)
    code, output = run(repo)
    assert code == 0, output
    assert git(repo, 'show', 'HEAD:tracked') == b'unstaged\n'
    assert (repo / 'tracked').read_text() == 'later change'
    assert git(repo, 'diff', '--cached') == b''
    assert git(repo, 'diff')

    repo = setup('hook-message')
    hook = repo / '.git/hooks/commit-msg'
    hook.write_text('#!/bin/sh\nprintf "Hook message\\n" > "$1"\n')
    hook.chmod(0o755)
    code, output = run(repo)
    assert code == 0 and git(repo, 'log', '-1', '--format=%s') == b'Hook message\n', output

    repo = setup('custom-model')
    code, output = run(repo, options=('--model', 'example-model'))
    assert code == 0, output

    repo = root / 'absent-index'
    repo.mkdir()
    git(repo, 'init', '-q')
    (repo / 'first').write_text('first file')
    code, output = run(repo, answer='n')
    assert code == 0 and index_bytes(repo) is None, output
    code, output = run(repo)
    assert code == 0 and git(repo, 'show', 'HEAD:first') == b'first file', output

    repo = setup('concurrent-index-hook')
    hook = repo / '.git/hooks/post-commit'
    hook.write_text('#!/bin/sh\ncp "$GIT_INDEX_FILE" .git/index\n')
    hook.chmod(0o755)
    code, output = run(repo)
    assert code != 0 and 'Commit succeeded' in output and 'not synchronized' in output, output
    assert git(repo, 'log', '-1', '--format=%B').decode().rstrip('\n') == message

    repo = setup('sparse')
    git(repo, 'config', 'core.sparseCheckout', 'true')
    code, output = run(repo)
    assert code != 0 and 'Sparse checkouts' in output, output

    repo = setup('assume-unchanged')
    git(repo, 'update-index', '--assume-unchanged', 'tracked')
    before = index_bytes(repo)
    code, output = run(repo)
    assert code != 0 and 'assume-unchanged' in output and index_bytes(repo) == before, output

    repo = setup('filter-failure')
    (repo / '.gitattributes').write_text('tracked filter=reject\n')
    git(repo, 'config', 'filter.reject.clean', 'false')
    git(repo, 'config', 'filter.reject.required', 'true')
    before = index_bytes(repo)
    code, output = run(repo)
    assert code != 0 and index_bytes(repo) == before, output

    repo = setup('new-submodule')
    nested = repo / 'nested'
    nested.mkdir()
    git(nested, 'init', '-q')
    (nested / 'file').write_text('nested content')
    git(nested, 'add', '.')
    git(nested, 'commit', '-qm', 'Nested initial commit')
    before = index_bytes(repo)
    code, output = run(repo)
    assert code != 0 and 'submodules separately' in output and index_bytes(repo) == before, output

    repo = setup('no-changes')
    git(repo, 'add', '.')
    git(repo, 'commit', '-qm', 'All changes')
    code, output = run(repo)
    assert code == 0 and 'No changes' in output, output

    repo = setup('merge')
    (repo / '.git/MERGE_HEAD').write_bytes(git(repo, 'rev-parse', 'HEAD'))
    code, output = run(repo)
    assert code != 0 and 'active Git operation' in output, output

    result = subprocess.run(['bash', script, '--repo', str(repo)], env=env, capture_output=True)
    assert result.returncode != 0 and b'interactive terminal' in result.stderr
    result = subprocess.run(['bash', script, '--help'], env=env, capture_output=True)
    assert result.returncode == 0 and b'--model' in result.stdout
    print('commit_by_codex tests passed')
PY
