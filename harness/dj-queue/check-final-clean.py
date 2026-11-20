#!/usr/bin/env python3
"""Guard PR #227 against temporary instrumentation leaking into the release.

This is a source guard, not an iOS runtime check. The normal phone driver is
intentionally kept; only the PR-specific endpoints and recorders go away.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
driver = (root/'tweak/Sources/Diagnostics/Driver.m').read_text()
assert 'SGDriverHandles' in driver and '@"tap"' in driver
for command in ('dj.state', 'dj.trace', 'dj.ui'):
    assert f'@"{command}"' not in driver, f'temporary endpoint: {command}'

for relative in (
    'tweak/Sources/Core/SGDJProbe.h',
    'tweak/Sources/Core/SGDJProbe.m',
    'tweak/Sources/Core/SGDJDiagnostics.h',
    'scripts/dj-diagnose.py',
    'scripts/dj-autotest.py',
    'scripts/dj-artwork-report.py',
    'scripts/dj-cap-capture.py',
    'scripts/dj-cap-occupancy.py',
):
    assert not (root/relative).exists(), f'temporary file in release: {relative}'

sources = root/'tweak/Sources'
for path in sources.rglob('*'):
    if not path.is_file() or path.suffix not in ('.m', '.x', '.h', '.inc'):
        continue
    text = path.read_text()
    for symbol in ('SGDJ_TRACE(', 'SGDJProbeRecord(', 'SGDJQueueDiagnostics(',
                   'SGDJArtworkTracePaint(', 'sampleDJCapCost('):
        assert symbol not in text, f'{symbol} remains in {path.relative_to(root)}'

queue = (sources/'Shared/Player/DJQueue.x').read_text()
assert 'if (boundURI.length && ![boundURI isEqualToString:kDJContext])' in queue
native = (sources/'Native/NowPlaying/DJQueueButton.m').read_text()
redesigned = (sources/'Redesigned/NowPlaying/DJQueueButton.m').read_text()
assert 'glassButtonConfiguration' not in native + redesigned
assert 'SGDJNativeDrawNextSet' in native
assert 'SGRDJQueueDrawNextSet' in redesigned
print('PR #227: temporary diagnostics removed, normal driver and flat buttons preserved')
