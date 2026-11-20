#!/usr/bin/env python3
"""Static safety assertions for the card identity policy in PR #227."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
text = (root / 'tweak/Sources/Shared/Player/DJArtworkIdentity.m').read_text()
assert 'BOOL explicitIdentity = containsDJIdentity(card.accessibilityLabel) || viewIdentifiesDJ(card, 0);' in text
assert 'BOOL confirmed = explicitIdentity || dedicated || editorial;' in text
assert 'editorialDJIdentity' in text and 'isDedicatedDJComponent' in text
assert 'return confirmed;' in text
assert 'if (playlistLabel(card.accessibilityLabel))' not in text, 'strong DJ identity masked by generic playlist label'
assert 'spotify:playlist:37i9dQZF1EYkqdzj48dyYq' in text, 'missing Spotify DJ URI identity'
print('DJ artwork identity priority: PASS (static; runtime card data still needs verification)')
