#!/usr/bin/env python3
"""Check DJQueue source split, state ownership, and subscription cap fallback."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[2]
player = root/'tweak/Sources/Shared/Player'
main = (player/'DJQueue.x').read_text()
parts = ('DJQueueState.inc', 'DJQueuePlayback.inc', 'DJQueueTransitions.inc', 'DJQueueHistory.inc')
assert len(main.splitlines()) < 1200, 'queue hooks grew too large'
for part in parts:
    assert f'#include "{part}"' in main
    code = (player/part).read_text()
    assert '%hook' not in code and '%orig' not in code and '%ctor' not in code
    assert len(code.splitlines()) > 200
assert 'SGDJQueueNextSetTapped' in main
assert 'SGDJNativeDrawNextSet' in main and 'SGRDJQueueDrawNextSet' in main
code = '\n'.join([main]+[(player/p).read_text() for p in parts])
assert 'if (boundURI.length && ![boundURI isEqualToString:kDJContext])' in code
assert 'id boundContext = [request respondsToSelector:@selector(contextURI)]' in code
assert 'DJ future tracks when the user switches' in code
assert 'sampleDJCapCost' not in code
assert 'SGDJQueueDiagnostics' not in code
print('DJ Queue split, scoped requests and hook ownership: PASS')

# Spotify 9.1.90 never emits a snackbar for synthetic DJ Edit/Remove rows.
# Hooking every UIControl to "undo" that hidden state can hijack a different
# snackbar, so this path is intentionally fail-closed. Native Spotify Undo
# remains untouched for normal queue rows.
assert 'isDJRemoveUndo(' not in main
assert 'sEditUndoButton' not in code
assert 'sEditUndoSnackbar' not in code
assert 'findSnackbarButtons(' not in main
assert 'snackbarRootForButton(' not in main
assert 'invokingDJUndo' not in main
assert 'queue-edit-toolbar-remove' in main and 'hideTrack(row, @"removed in Edit")' in main
print('DJ Edit removal leaves unrelated Spotify snackbar actions untouched: PASS')
