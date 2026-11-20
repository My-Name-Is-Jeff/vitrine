# Next DJ Set — direct neutral request

Run `python3 harness/dj-pick/check.py`. Portable assertions check that the
queue action invokes `SGDJPickRequest`, that `DJPick.x` hooks no native Spotify
class or button, that the old fallback switch and six-second native jump are
absent, and that the suggested prompt is dispatched directly once. On macOS,
the harness additionally compiles the production request/landing tracker with
Foundation fakes and the real protobuf codec.

## Spotify 9.1.90 observed behavior

Previously the native `CompositeJumpable` sent `signal_id: "jump"`, whose local
completion could say success while the playlist service returned HTTP 502. A
native suggested prompt used `signal_id: "prompt"` with a base64 protobuf: field
1 is the English suggestion, field 2 is 3 (suggested request). This produced a
new `list_intro_item` and DJ page in the simulator.

Now the **Next DJ Set** button's **Let DJ pick (request)** action sends that
neutral suggested `prompt` once immediately, without the native `jump`. The
English request is “Surprise me with a new mix based on my taste.”
There is no `Neutral request fallback` setting, and the native Let DJ pick
button has no Vitrine interception: its own behavior remains Spotify's.

The request tracker requires a real landing in a new DJ page/intro; it ignores
old-page progression and manually queued tracks. A pause, leaving the DJ
context or a 20-second timeout finishes the attempt. A failed/cancelled request
keeps the custom queue order; on success it clears that order and fetches the
new tracks. Two taps during one attempt share the same request. The code also
removes the old prefetch so it cannot play ahead of the new set.

The new code has **not yet been exercised against a live simulator**. Check
request mode, native Let DJ pick independence, skip mode and both default-on
switches in Spotify 9.1.90 after applying the patch.
