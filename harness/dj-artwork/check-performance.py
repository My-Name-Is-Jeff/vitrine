#!/usr/bin/env python3
"""Static and reference checks for the low-risk DJ artwork hot-path changes.

These cannot measure UIKit time on macOS. They ensure the optimizations remain
idempotent and the card/placeholder policy is unchanged by the rendering edits.
"""
from pathlib import Path
from dataclasses import dataclass

root = Path(__file__).resolve().parents[2]
identity = (root / 'tweak/Sources/Shared/Player/DJArtworkIdentity.m').read_text()

for look, prefix in [('Native', 'SGDJ'), ('Redesigned', 'SGRDJ')]:
    source = (root / f'tweak/Sources/{look}/Home/DJArtwork.x').read_text()
    assert f'objc_getAssociatedObject(holder, &{prefix}OverlayKey)' in source
    assert f'objc_setAssociatedObject(holder, &{prefix}OverlayKey, overlay' in source
    assert f'objc_setAssociatedObject(holder, &{prefix}OverlayKey, nil' in source
    assert f'objc_getAssociatedObject(holder, &{prefix}RegisteredHolderKey)' in source
    assert 'viewWithTag:' not in source
    assert 'if (!CGRectEqualToRect(overlay.frame, holder.bounds))' in source
    assert f'if (overlay.image != {prefix}Cover)' in source
    assert 'if (holder.subviews.lastObject != overlay)' in source
    assert 'if (overlay.superview != holder) [holder addSubview:overlay];' in source
    assert f'SGDJArtworkIsConfirmedCard(row)' in source
    assert f'SGDJArtworkNeedsPlaceholder(row, holder, &retry)' in source

assert 'now - frame.checkedAt < (1.0 / 120.0)' in identity
assert 'frame.window == window' in identity
assert 'frame.label isEqualToString:label' in identity
assert 'frame.identifier isEqualToString:identifier' in identity
assert 'if (sgNativeUIImage(holder, 0) || sgNativeRasterLayer(holder.layer, 0))' in identity
assert 'state.resolvedNativeArtwork' in identity
assert 'now - state.firstMissing >= 0.8' in identity

@dataclass
class Memo:
    key: tuple = ()
    at: float = -1
    confirmed: bool = False
    computations: int = 0

    def check(self, card, label, identifier, window, at, classify):
        key = (card, label, identifier, window)
        if self.key == key and 0 <= at - self.at < (1 / 120):
            return self.confirmed
        self.computations += 1
        self.key, self.at, self.confirmed = key, at, classify
        return classify

memo = Memo()
assert memo.check('card1', 'DJ, Playlist', 'Recents', 'window1', 1.0, False) is False
assert memo.check('card1', 'DJ, Playlist', 'Recents', 'window1', 1.002, True) is False
assert memo.computations == 1, 'reuse within one frame'
assert memo.check('card1', 'DJ, Playlist', 'Recents', 'window1', 1.01, True) is True
assert memo.computations == 2, 'negative results expire on the next frame'
assert memo.check('card1', 'New title', 'Recents', 'window1', 1.011, False) is False
assert memo.check('card1', 'New title', 'Recents', 'window2', 1.012, True) is True
assert memo.check('card2', 'New title', 'Recents', 'window2', 1.013, False) is False
assert memo.computations == 5, 'label/window/card changes invalidate cached decision'

print('DJ artwork rendering hot path: PASS (static + memoization reference model)')
