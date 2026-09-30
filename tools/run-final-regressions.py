"""Run the same behavioral probes against the original baseline and FINAL on macOS."""
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

root = Path.cwd()
workflow = (root / '.github/workflows/build-ios.yml').read_text()
block = workflow.split('- name: Capture activity contract')[1].split('- name:')[0]
sources = re.findall(r'\s+([\w/.-]+\.swift)\s+\\', block)
sources = [p for p in sources if not p.startswith('tools/')]
probe = root / 'tools/FinalRegressionCheck/main.swift'
baseline = 'c86503472165a24d24a41e297febca481bb6c14b'
with tempfile.TemporaryDirectory(prefix='final-regression-') as tmp:
    tmp = Path(tmp)
    old = tmp / 'baseline'
    old.mkdir()
    archive = subprocess.check_output(['git', 'archive', baseline])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(old, filter='data')
    for label, folder in [('baseline', old), ('final', root)]:
        exe = tmp / label
        if label == 'baseline':
            exe = tmp / 'baseline-probe'
        subprocess.run(['swiftc', '-swift-version', '5', *[str(folder / p) for p in sources],
                        str(probe), '-o', str(exe)], check=True)
        result = subprocess.run([str(exe)], text=True, capture_output=True)
        print(label, result.stdout, flush=True)
        if label == 'baseline':
            assert result.returncode != 0 and result.stdout.count('FAIL ') == 3, result.stdout + result.stderr
        else:
            assert result.returncode == 0 and result.stdout.count('PASS ') == 3, result.stdout + result.stderr
print('FINAL red/green regression proof passed')
