#!/usr/bin/env python3
"""Reference behavior for native-first DJ artwork fallback (Spotify 9.1.90).

This models the Objective-C state transitions; on-device verification still
needs both the real AI DJ card and a user playlist named DJ.
"""
from dataclasses import dataclass


@dataclass
class Slot:
    card: object = None
    first_missing: float = 0.0
    native_resolved: bool = False

    def step(self, card, candidate, at, native_image=False, layer_image=False):
        if not candidate:
            self.card, self.first_missing, self.native_resolved = None, 0.0, False
            return False
        if card is not self.card:
            self.card, self.first_missing, self.native_resolved = card, 0.0, False
        if self.native_resolved:
            return False
        if native_image or layer_image:
            self.native_resolved, self.first_missing = True, 0.0
            return False
        if self.first_missing <= 0:
            self.first_missing = at
        return at - self.first_missing >= 0.8


def verify():
    official, user, recycled = object(), object(), object()
    slot = Slot()
    # A genuinely artless official DJ card is still eligible after the grace period.
    assert not slot.step(official, True, 1.0)
    assert slot.step(official, True, 1.9)
    assert slot.step(official, True, 2.1)
    # Native cover arriving after fallback must remove the overlay immediately.
    assert not slot.step(official, True, 2.2, native_image=True)
    assert not slot.step(official, True, 3.1)
    # A recycled view must not inherit either the fallback or native-art verdict.
    assert not slot.step(recycled, True, 4.0)
    assert slot.step(recycled, True, 4.9)
    # User playlist's real artwork wins even if seen on the *first* observation.
    assert not slot.step(user, True, 5.0, native_image=True)
    assert not slot.step(user, True, 6.0, native_image=True)
    # An Encore/SwiftUI layer-backed bitmap is authoritative too.
    assert not slot.step(recycled, True, 7.0, layer_image=True)
    assert not slot.step(recycled, True, 8.0, layer_image=True)
    # Removing the candidate resets the cell state.
    assert not slot.step(None, False, 9.0)
    print('DJ artwork native-first continuity: 12 reference checks PASS')


if __name__ == '__main__':
    verify()
