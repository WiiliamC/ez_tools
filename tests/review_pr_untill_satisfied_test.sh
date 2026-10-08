#!/usr/bin/env bash
set -euo pipefail
repo_root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
python3 - "$repo_root" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='review-pr-test-') as directory:
    root = Path(directory)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    codex = bin_dir / 'codex'
    codex.write_text(r'''#!/usr/bin/env python3
import json, os, re, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
prompt = args[-1]
review = '--output-schema' in args
mode = os.environ.get('MOCK_MODE', 'pass')
log = Path(os.environ['MOCK_CALLS'])
calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
call = {'review': review, 'args': args, 'prompt': prompt}
if '--ephemeral' in args:
    prompt = sys.stdin.read()
    with log.open('a') as stream:
        stream.write(json.dumps({'review': False, 'commit': True, 'args': args, 'prompt': prompt}) + '\n')
    result = {'ready': True, 'message': 'Simplify branch changes'}
    print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': json.dumps(result)}}))
    print(json.dumps({'type': 'turn.completed'}))
    sys.exit(0)
if review:
    assert '$review-changes' in prompt
    for required in ('independent sub-agent', 'simplify-changes', '[Simplify]',
                     'behavior-preserving', 'review_completed=false',
                     'relevant untracked files', 'git diff HEAD', 'evidence verification'):
        assert required in prompt, required
    merge_base = re.search(r'Fixed merge-base: ([0-9a-f]+)', prompt).group(1)
    def git(*args):
        return subprocess.check_output(['git', *args], text=True)
    call['committed'] = git('diff', '--name-only', merge_base, 'HEAD').splitlines()
    call['staged'] = git('diff', '--cached', '--name-only').splitlines()
    call['unstaged'] = git('diff', '--name-only').splitlines()
    call['untracked'] = git('ls-files', '--others', '--exclude-standard').splitlines()
else:
    assert '$review-changes' not in prompt
    assert '[Simplify]' in prompt and 'preserving' in prompt
with log.open('a') as stream:
    stream.write(json.dumps(call) + '\n')
print(json.dumps({'type': 'thread.started', 'thread_id': 'mock-session'}), flush=True)
if mode == 'fail' and review:
    sys.exit(7)
if mode == 'timeout' and review:
    print(json.dumps({'type': 'error', 'message': 'request timed out'}), flush=True)
    import time
    time.sleep(30)
if mode.startswith('move-during-') and (
    (review and mode in ('move-during-review', 'move-during-findings'))
    or (not review and mode == 'move-during-fix')
):
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    subprocess.run(['git', 'update-ref', 'refs/heads/main', head], check=True)
if mode == 'delete-during-review' and review:
    subprocess.run(['git', 'branch', '-D', 'main'], check=True, stdout=subprocess.DEVNULL)
if not review:
    Path('branch.txt').write_text('simplified\n')
    sys.exit(0)
findings = []
completed = mode != 'missing-skill'
summary = 'Missing skill or delegation capability' if not completed else 'Review complete'
if mode in ('simplify', 'move-during-findings', 'move-during-fix') and not any(not call['review'] for call in calls):
    findings = [{'issue': '[Simplify] branch.txt:1: remove duplicate operation; preserve output; evidence: repeated work; lower complexity, low risk'}]
if mode == 'advisory':
    summary = 'Advisory scope change: remove a supported feature; not applied. Verification: inspected full diff.'
result = {'review_completed': completed, 'satisfied': completed and not findings,
          'summary': summary, 'findings': findings}
Path(args[args.index('--output-last-message') + 1]).write_text(json.dumps(result))
''')
    codex.chmod(0o755)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('GIT_') and not key.startswith('REVIEW_UNTIL_')}
    env.update(PATH=str(bin_dir) + os.pathsep + env['PATH'],
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               XDG_STATE_HOME=str(root / 'state'))

    def git(repo, *args):
        return subprocess.check_output(['git', '-C', str(repo), *args], env=env,
                                       text=True, stderr=subprocess.PIPE).strip()

    def repository(name, base='main'):
        repo = root / name
        repo.mkdir()
        git(repo, 'init', '-q', '-b', base)
        git(repo, 'config', 'user.email', 'test@example.com')
        git(repo, 'config', 'user.name', 'Test User')
        (repo / 'base.txt').write_text('base\n')
        git(repo, 'add', '.')
        git(repo, 'commit', '-qm', 'base')
        git(repo, 'checkout', '-qb', 'feature')
        (repo / 'branch.txt').write_text('branch\n')
        git(repo, 'add', '.')
        git(repo, 'commit', '-qm', 'feature')
        return repo

    def calls(repo):
        path = root / (repo.name + '-calls')
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def run(repo, *options, mode='pass', entry='pr', default_logs=False, commit=False):
        if commit:
            args = ['bash', str(source / 'review_and_commit.sh'), '--review-scope', 'branch', '--repo', str(repo)]
        else:
            args = ['bash', str(source / f'review_{entry}_untill_satisfied.sh'), '--repo', str(repo)]
        if not default_logs and not any(option.startswith('--resume') for option in options):
            args += ['--log-dir', str(root / (repo.name + '-logs'))]
        return subprocess.run(args + list(options), env=dict(env, MOCK_MODE=mode,
                              MOCK_CALLS=str(root / (repo.name + '-calls'))),
                              capture_output=True, text=True, timeout=15)

    def state(repo, default_logs=False, entry='pr'):
        logs = (root / 'state' / f'review_{entry}_untill_satisfied' / repo.name / 'logs'
                if default_logs else root / (repo.name + '-logs'))
        paths = list(logs.glob('*.log.state.json'))
        assert len(paths) == 1, paths
        path = paths[0]
        return path, json.loads(path.read_text())

    def expect(result, code, text=''):
        assert result.returncode == code, (result.returncode, result.stdout, result.stderr)
        assert text in result.stdout + result.stderr, (text, result)

    # Main wins even with a different local master. Use merge-base, not main tip.
    repo = repository('full-scope')
    base = git(repo, 'rev-parse', 'main')
    git(repo, 'branch', 'master', 'HEAD')
    tree = git(repo, 'rev-parse', 'main^{tree}')
    new_main = git(repo, 'commit-tree', tree, '-p', base, '-m', 'advance main')
    git(repo, 'update-ref', 'refs/heads/main', new_main)
    (repo / 'staged.txt').write_text('staged\n')
    git(repo, 'add', 'staged.txt')
    (repo / 'base.txt').write_text('unstaged\n')
    (repo / 'untracked.txt').write_text('untracked\n')
    expect(run(repo, default_logs=True), 0)
    _, saved = state(repo, True)
    assert saved['review_mode'] == 'pr' and saved['base_branch'] == 'main'
    assert saved['base_commit'] == new_main and saved['merge_base'] == base
    call = calls(repo)[0]
    assert call['committed'] == ['branch.txt']
    assert call['staged'] == ['staged.txt'] and call['unstaged'] == ['base.txt']
    assert call['untracked'] == ['untracked.txt']
    assert '--sandbox' in call['args'] and 'read-only' in call['args']

    repo = repository('master-fallback', 'master')
    expect(run(repo), 0)
    assert state(repo)[1]['base_branch'] == 'master'

    repo = repository('remote-only', 'trunk')
    git(repo, 'update-ref', 'refs/remotes/origin/main', git(repo, 'rev-parse', 'trunk'))
    expect(run(repo), 2, 'requires a local main or master')
    assert not calls(repo)

    repo = repository('unrelated')
    tree = git(repo, 'rev-parse', 'main^{tree}')
    unrelated = git(repo, 'commit-tree', tree, '-m', 'unrelated root')
    git(repo, 'update-ref', 'refs/heads/main', unrelated)
    expect(run(repo), 2, 'Cannot compute merge-base')
    assert not calls(repo)

    repo = repository('simplify')
    expect(run(repo, '--max-loops', '2', mode='simplify'), 0)
    trace = calls(repo)
    assert [call['review'] for call in trace] == [True, False, True]
    assert trace[-1]['unstaged'] == ['branch.txt']
    assert (repo / 'branch.txt').read_text() == 'simplified\n'
    assert git(repo, 'log', '-1', '--format=%s') == 'feature'

    repo = repository('advisory')
    expect(run(repo, mode='advisory'), 0, 'Advisory scope change')
    assert len(calls(repo)) == 1

    repo = repository('missing-skill')
    expect(run(repo, mode='missing-skill'), 2, 'Review could not be completed')
    assert len(calls(repo)) == 1
    log = state(repo)[1]['log_path']
    expect(run(repo, '--resume', log), 0)
    assert all(call['review'] for call in calls(repo))

    # Failed review resumes the same session with the skill and fixed scope.
    repo = repository('resume')
    expect(run(repo, mode='fail', default_logs=True), 7)
    _, saved = state(repo, True)
    expect(run(repo, '--resume', saved['log_path'], entry='changes'), 2, 'mode does not match')
    assert len(calls(repo)) == 1
    expect(run(repo, '--resume', default_logs=True), 0)
    trace = calls(repo)
    assert trace[-1]['args'][:3] == ['exec', 'resume', 'mock-session']
    assert trace[0]['prompt'] == trace[-1]['prompt']
    assert 'sandbox_mode="read-only"' in trace[-1]['args']

    repo = repository('timeout')
    expect(run(repo, mode='timeout'), 124, 'timed out')
    log = state(repo)[1]['log_path']
    expect(run(repo, '--resume', log), 0)
    assert calls(repo)[-1]['args'][:3] == ['exec', 'resume', 'mock-session']

    repo = repository('moved-base')
    expect(run(repo, mode='fail'), 7)
    path, saved = state(repo)
    git(repo, 'update-ref', 'refs/heads/main', git(repo, 'rev-parse', 'HEAD'))
    expect(run(repo, '--resume', saved['log_path'], '--allow-worktree-changes'), 2, 'baseline main changed')
    assert len(calls(repo)) == 1 and json.loads(path.read_text()) == saved

    repo = repository('deleted-base')
    expect(run(repo, mode='fail'), 7)
    _, saved = state(repo)
    git(repo, 'branch', '-D', 'main')
    expect(run(repo, '--resume', saved['log_path']), 2, 'baseline main changed')
    assert len(calls(repo)) == 1

    # A baseline changed during a phase must not permit approval or a later fix.
    for mode, expected_calls in (('move-during-review', 1),
                                 ('delete-during-review', 1),
                                 ('move-during-findings', 1),
                                 ('move-during-fix', 2)):
        repo = repository(mode)
        expect(run(repo, '--max-loops', '2', mode=mode), 2, 'baseline main changed')
        assert len(calls(repo)) == expected_calls
        _, saved = state(repo)
        assert saved['run_status'] == 'resumable' and saved['phase_status'] == 'failed'

    # Exercise the complete tool with real temporary Git commits and mock Codex.
    repo = repository('review-fix-commit')
    original_head = git(repo, 'rev-parse', 'HEAD')
    expect(run(repo, '--max-loops', '2', mode='simplify', commit=True), 0)
    trace = calls(repo)
    assert [call['review'] for call in trace] == [True, False, True, False]
    assert trace[-1]['commit'] and '--ephemeral' in trace[-1]['args']
    assert git(repo, 'rev-parse', 'HEAD') != original_head
    assert git(repo, 'log', '-1', '--format=%s') == 'Simplify branch changes'
    assert git(repo, 'status', '--porcelain') == ''
    repo = repository('review-incomplete-no-commit')
    original_head = git(repo, 'rev-parse', 'HEAD')
    expect(run(repo, mode='missing-skill', commit=True), 2)
    assert git(repo, 'rev-parse', 'HEAD') == original_head
    assert len(calls(repo)) == 1 and calls(repo)[0]['review']
    repo = repository('review-clean-no-commit')
    original_head = git(repo, 'rev-parse', 'HEAD')
    expect(run(repo, commit=True), 0, 'No changes to commit')
    assert git(repo, 'rev-parse', 'HEAD') == original_head
    assert len(calls(repo)) == 1

    # Older checkpoints lacking a mode remain valid only for local changes.
    repo = repository('legacy')
    expect(run(repo, mode='fail'), 7)
    path, saved = state(repo)
    for key in ('review_mode', 'base_branch', 'base_commit', 'merge_base'):
        saved.pop(key)
    saved['phase_status'] = 'completed'
    saved['session_id'] = ''
    saved['run_status'] = 'resumable'
    path.write_text(json.dumps(saved))
    Path(saved['log_path'] + '.review.json').write_text(json.dumps({
        'review_completed': True, 'satisfied': True, 'summary': 'Legacy complete review', 'findings': []}))
    expect(run(repo, '--resume', saved['log_path']), 2, 'mode does not match')
    expect(run(repo, '--resume', saved['log_path'], entry='changes'), 0, 'Legacy complete review')
    assert state(repo)[1]['review_mode'] == 'changes'
    assert len(calls(repo)) == 1
    expect(run(repo, '--resume', saved['log_path']), 2, 'mode does not match')

print('review_pr_untill_satisfied tests passed')
PY
