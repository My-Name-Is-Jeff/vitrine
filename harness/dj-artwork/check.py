#!/usr/bin/env python3
"""Static guards for DJ artwork identity, lifecycle and render probes.

These checks do not replace a Spotify simulator test: a DJ card with no model
URI in UIKit is still ambiguous with a user playlist of the same name.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
identity = (root / 'tweak/Sources/Shared/Player/DJArtworkIdentity.m').read_text()
header = (root / 'tweak/Sources/Shared/Player/DJArtworkIdentity.h').read_text()
assert 'BOOL explicitIdentity = containsDJIdentity(card.accessibilityLabel) || viewIdentifiesDJ(card, 0);' in identity
assert 'BOOL confirmed = explicitIdentity || dedicated || editorial;' in identity
assert 'editorialDJIdentity' in identity and 'isDedicatedDJComponent' in identity
assert 'return confirmed;' in identity
assert 'if (playlistLabel(card.accessibilityLabel))' not in identity
assert 'spotify:playlist:37i9dQZF1EYkqdzj48dyYq' in identity
assert '[holder isDescendantOfView:cache.card]' in identity, 'cached parent card may be stale on cell reuse'
assert 'state.card != card' in identity, 'fallback state must not leak to a new card'
assert 'if (state.resolvedNativeArtwork) return NO;' in identity
assert 'if (sgNativeUIImage(holder, 0) || sgNativeRasterLayer(holder.layer, 0)) {' in identity, 'existing Spotify artwork must outrank the title-based fallback'
assert 'sgIsVitrineOverlay(view) || sgIsPlaceholder(view)' in identity, 'exclude synthetic DJ overlays and native placeholders'
assert 'state.resolvedNativeArtwork = YES;' in identity
assert 'now - state.firstMissing >= 0.8' in identity
for look in ('Native', 'Redesigned'):
    art = (root / f'tweak/Sources/{look}/Home/DJArtwork.x').read_text()
    assert 'SGDJArtworkIsConfirmedCard(row)' in art
    assert 'SGDJArtworkNeedsPlaceholder(row, holder, &retry)' in art
    assert 'SGDJArtworkEnclosingCard(holder)' in art
    assert 'if (retry)' in art and 'dispatch_after(' in art
    assert 'SGDJLabel(' not in art and 'SGRDJLabel(' not in art
print('DJ artwork: identity, cell reuse, placeholder continuity and overlay updates PASS (static)')
