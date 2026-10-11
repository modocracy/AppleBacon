#!/usr/bin/env python3
"""Reject tracked files outside the reviewed, file-by-file public allowlist.

Reads paths and Git metadata only; never prints file contents or private inputs.
Run before publishing and in CI. Local ignored research/QA files stay untouched.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def violations(root: Path) -> list[str]:
    tracked = subprocess.run(
        ['git', 'ls-files', '-z'], cwd=root, check=True, capture_output=True,
    ).stdout
    ignored = subprocess.run(
        ['git', 'check-ignore', '--no-index', '--stdin', '-z'],
        cwd=root, input=tracked, capture_output=True,
    )
    if ignored.returncode not in (0, 1):
        raise RuntimeError('Git could not validate the publication allowlist')
    problems = [f'tracked but private: {p.decode()}' for p in ignored.stdout.split(b'\0') if p]
    for path in tracked.split(b'\0'):
        if path and (root / path.decode()).is_symlink():
            problems.append(f'public symlink is not allowed: {path.decode()}')
    # An explicit file review is required before admitting new public files.
    for rule in (root / '.gitignore').read_text().splitlines():
        if rule.startswith('!') and any(c in rule for c in '*?['):
            problems.append(f'broad public allowlist rule: {rule}')
    return sorted(problems)


def main() -> int:
    problems = violations(ROOT)
    if problems:
        print('Public source audit failed:')
        for problem in problems:
            print(f'  {problem}')
        print('Preserve local files; remove private paths from the Git index.')
        return 1
    print('Public source audit passed: tracked paths match the explicit allowlist.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
