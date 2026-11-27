#!/usr/bin/env python3
"""Prepare only the standalone optional Pod; Core never downloads or builds LLVM."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import venv


def main():
    """Build verified LLVM sources in a private cache and publish artifacts before CocoaPods source pruning."""
    root = Path(__file__).resolve().parents[2]
    cache = Path(os.environ.get('CCK_PROFILE_MERGE_CACHE',
                              str(Path(tempfile.gettempdir()) / 'codecoveragekit-llvm-20.1.8'))).resolve()
    cache.mkdir(parents=True, exist_ok=True)
    environment = cache / 'venv'
    python = environment / 'bin/python3'
    if not python.exists():
        venv.EnvBuilder(with_pip=True).create(environment)
    check = "import importlib.metadata as m; assert m.version('cmake') == '3.31.6' and m.version('ninja') == '1.11.1.4'"
    if subprocess.run([str(python), '-c', check], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode:
        subprocess.run([str(python), '-m', 'pip', 'install', 'cmake==3.31.6', 'ninja==1.11.1.4'], check=True)
    env = dict(os.environ)
    env['PATH'] = str(environment / 'bin') + os.pathsep + env.get('PATH', '')
    subprocess.run([sys.executable, str(root / 'Tools/ProfileMerge/build.py'),
                    '--cache', str(cache), '--output', str(root / 'ProfileMergeSupport/Artifacts'),
                    '--developer-dir', env.get('DEVELOPER_DIR', '/Applications/Xcode263.app/Contents/Developer')],
                   env=env, check=True)


if __name__ == '__main__':
    main()
