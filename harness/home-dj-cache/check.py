#!/usr/bin/env python3
"""Verify DJ section searches are cached and invalidated on reuse."""
from pathlib import Path
src = (Path(__file__).resolve().parents[2] /
       'tweak/Sources/Redesigned/Home/HomeSections.x').read_text()
assert 'static BOOL sectionContainsDJ(UICollectionViewCell *cell, UIView *root)' in src
assert 'sectionContainsDJ(cell, rootBefore)' in src
assert 'sectionContainsDJ(cell, rootAfter)' in src
assert 'if (rootAfter != rootBefore)' in src
assert 'cachedShape.unsignedIntegerValue == shape' in src
assert 'now - checkedAt.doubleValue < 0.25' in src
assert 'invalidateDJSectionCache((UICollectionViewCell *)self)' in src
assert src.count('containsDJCard(') == 3, 'recursive helper and a single cache miss only'
print('Home DJ subtree cache/invalidation: PASS')
