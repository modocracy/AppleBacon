"""Publication checks must catch force-added private data without reading it."""
import importlib.util
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('public_files', ROOT / 'tools/check_public_files.py')
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def repo(tmp_path):
    subprocess.run(['git', 'init', '-q', str(tmp_path)], check=True)
    (tmp_path / '.gitignore').write_text('/*\n!/.gitignore\n!/README.md\n')
    (tmp_path / 'README.md').write_text('Public guide\n')
    subprocess.run(['git', 'add', '.gitignore', 'README.md'], cwd=tmp_path, check=True)
    return tmp_path


def test_local_private_files_are_allowed_but_force_added_files_fail(tmp_path):
    root = repo(tmp_path)
    private = root / 'research' / 'capture.txt'
    private.parent.mkdir()
    private.write_text('private fixture content must not appear in audit output')
    assert audit.violations(root) == []
    subprocess.run(['git', 'add', '-f', 'research/capture.txt'], cwd=root, check=True)
    assert audit.violations(root) == ['tracked but private: research/capture.txt']
    assert private.read_text() == 'private fixture content must not appear in audit output'


def test_new_files_need_explicit_allowlist_entry(tmp_path):
    root = repo(tmp_path)
    (root / 'draft.md').write_text('Unreviewed draft')
    subprocess.run(['git', 'add', '-f', 'draft.md'], cwd=root, check=True)
    assert audit.violations(root) == ['tracked but private: draft.md']
    with (root / '.gitignore').open('a') as out:
        out.write('!/draft.md\n')
    assert audit.violations(root) == []


def test_broad_source_exceptions_are_rejected(tmp_path):
    root = repo(tmp_path)
    with (root / '.gitignore').open('a') as out:
        out.write('!/src/\n/src/*\n!/src/*.lua\n')
    assert audit.violations(root) == ['broad public allowlist rule: !/src/*.lua']


def test_allowlisted_symlink_cannot_expose_private_data(tmp_path):
    root = repo(tmp_path)
    (root / 'README.md').unlink()
    (root / 'README.md').symlink_to('private-notes.md')
    (root / 'private-notes.md').write_text('Private')
    subprocess.run(['git', 'add', 'README.md'], cwd=root, check=True)
    assert audit.violations(root) == ['public symlink is not allowed: README.md']
