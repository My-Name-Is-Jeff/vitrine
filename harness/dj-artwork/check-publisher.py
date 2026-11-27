#!/usr/bin/env python3
"""Regression cases from Spotify 9.1.90 Home/Recents accessibility labels.

Reference parser mirrors the conservative Objective-C decision. This is not a
UIKit runtime test; on-device acceptance is required before merging.
"""
from pathlib import Path

source = (Path(__file__).resolve().parents[2] /
          'tweak/Sources/Shared/Player/DJArtworkIdentity.m').read_text()
for token in (
    'static SGDJArtworkPublisher sgDJCardPublisher(UIView *card)',
    'SGDJArtworkPublisherSpotify',
    'SGDJArtworkPublisherOther',
    'SGDJArtworkPublisherUnknown',
    'parts[parts.count - 2]',
    '[category.lowercaseString hasSuffix:@". playlist"]',
    '[publisher caseInsensitiveCompare:@"Spotify"]',
    'if (publisher == SGDJArtworkPublisherOther) return NO;',
    'if (publisher == SGDJArtworkPublisherSpotify) confirmed = YES;',
    'BOOL candidate = sgDJCardPublisher(card) == SGDJArtworkPublisherSpotify;',
):
    assert token in source, f'identity policy unexpectedly changed: {token}'


def publisher(card_id, label):
    kinds = {'Components.UI.HomeCard', 'Components.UI.RecentsListRow',
             'Shortcut.Card.Home'}
    if card_id not in kinds or not (label == 'DJ' or label.startswith(
            ('DJ,', 'DJ.', 'Your DJ', 'AI DJ'))):
        return 'unknown'
    parts = label.split(',')
    if len(parts) < 2:
        return 'unknown'
    category = parts[-2].strip().lower()
    if category != 'playlist' and not category.endswith('. playlist'):
        return 'unknown'
    final = parts[-1].strip()
    if not final:
        return 'unknown'
    return 'spotify' if final.lower() == 'spotify' else 'other'


for kind, label, expected in (
    ('Components.UI.HomeCard', 'DJ, Playlist, Spotify', 'spotify'),
    ('Components.UI.HomeCard', 'DJ, Playlist, Some User', 'other'),
    ('Components.UI.RecentsListRow', 'DJ. 51 songs played, Playlist, Spotify', 'spotify'),
    ('Components.UI.RecentsListRow', 'DJ. 39 songs played, Playlist, Spotify', 'spotify'),
    ('Components.UI.RecentsListRow', 'DJ. Playlist, Some User', 'other'),
    ('Components.UI.HomeCard', 'DJ, Playlist, Spotify, Playlist, Some User', 'other'),
    ('Components.UI.HomeCard', 'DJ, Playlist', 'unknown'),
    ('Components.UI.HomeCard', 'DJ, Playlist, ', 'unknown'),
    ('Components.UI.HomeCard', 'My DJ, Playlist, Spotify', 'unknown'),
    ('Components.UI.HomeCard', 'DJ, Playlist, Spotify Likes', 'other'),
):
    got = publisher(kind, label)
    assert got == expected, (kind, label, got, expected)
print('DJ publisher identity: PASS (reference cases and static source assertions)')
