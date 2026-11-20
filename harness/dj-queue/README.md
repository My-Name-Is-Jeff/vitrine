# DJ queue regression checks

Run `python3 harness/dj-queue/check.py` on macOS. It compiles the production
history and spent-track decision functions from `DJQueue.x` against Foundation
fakes, then checks passed rows, queue-copy identities, removed rows, previous and
next history entries, and skipping spent context tracks before their audio starts.

Spotify 9.1.90, iOS 26.3, redesigned look, isolated **Vitrine DJ** simulator
(driver port 8087), 2026-11-17:

- The original five tracks were Another One Bites The Dust, I Feel It Coming,
  Billie Jean, Left and Right, and Cool. Tapping Billie Jean and then Cool,
  Previous visited Left and Right → Billie Jean → I Feel It Coming →
  Another One Bites The Dust. Next visited the same four tracks forwards.
- Previous was tested after seeking to zero, retaining Spotify's behavior that
  a press beyond the first three seconds restarts the current track.

The simulator checks verify track transitions and UI state. They do not measure
audio samples or certify phone audio behavior.

The production asynchronous handover is also exercised with a fake core that delays
skip acknowledgements and resumes on skip, as Spotify 9.1.90 does. The real
output gate is checked on two PCM buffers, then released without changing samples.
The lossless handoff app completed on the isolated simulator with `RESULT failures=0`.
Its player-observer stub was updated for the current SpeedPitch subscription, and
its recovery assertion now waits for the recovery callback rather than overtaking
it on a busy simulator.

`historyFutureRows` projects the entries after the current logical history position
back into both the queue page and the now-playing lens. The checks include a
queued copy as the current track, rows passed by a tap, removed rows and the end
of the history. Already played tracks are restored only as visible upcoming rows;
the bookkeeping used to avoid repeats is retained.

Follow-up UI check on the same simulator: after tapping Mad Love past BLOCKKIDS
and LOCKED IN FREESTYLE, Previous returned to LOCKED IN FREESTYLE and then
BLOCKKIDS. The queue then displayed LOCKED IN FREESTYLE → Mad Love → Job's Not
Done, restoring the passed row before the tapped track. Ordinary Next/Previous
also restored BLOCKKIDS after returning to Rottweiler.

Shared-UID outro regression: the core may land on a spent song before a
`spotify:media:` item with the same UID. Confirmation now checks the physical URI,
and the muted bridge advances over a context original and its known queue copy
before releasing the voice. The checks assert that the gate stays closed while
those songs are current and that the displayed song/clock remain the held snapshot.
The temporary `dj.state` recorder was removed before the PR review; use
the normal player and queue checks for runtime validation.

Logical-final-song prefetch regression: an owned queued copy is ignored when
checking whether only that logical song remains, reused rather than queued twice,
and played after the context anchor has produced the next segment. The checks
also cover an unqueued logical last and a current queue copy of the physical last.
The deadline watcher remains active across future-only reports.

Live simulator check: moved Favorite Lie ahead of KRYPTONITE/YOSEMITE, then let
KRYPTONITE finish automatically. The internal Favorite Lie anchor retained
KRYPTONITE on screen; the main play button stayed Pause in all sampled handover
states. YOSEMITE started automatically with the next segment's introduction and
five songs already present in the core future.

New DJ set button (Spotify 9.1.90, Vitrine DJ simulator): the queue header action was
visually checked beside Edit, including its 44 pt touch area and hiding in Edit.
Native “Let DJ pick” invokes CompositeJumpable.jumpWithCompletion: with
`void (^)(NSError *)`. Its acknowledgement can precede an HTTP 502 on the playlist
signal endpoint, leaving playback unchanged. The recovery and new before/after
checks are documented in `../dj-pick/README.md`.

Reordered DJ segment outro regression (three simulator reproductions, 2026-11-17):
when a moved track played from a core queue copy, a spent context original
briefly played again before the physical last song's `spotify:media:` outro.
The existing early-outro bridge covered only an *adjacent* repeat of the
current song and was triggered by the deadline watcher, not by Next. The
bridge now traverses other already-played/hidden context originals as well,
and the physical Next hook invokes it before Spotify can play them. The
bridge issues targeted skips under the independent render-thread mute without
pausing the Spotify transport; it keeps audio muted until landing is confirmed. The regression fixture also checks
that an unplayed DJ song, user-queued song or pending order is never skipped.

Follow-up (transport flicker): a segment-ending reorder used to call Pause, wait for
acknowledgement, then skip the anchor and Resume. The muted output gate already
blocks playback of those unwanted originals, so the reordered-track handovers
now perform the targeted skips with playback running and acknowledge the
landing before unmuting. The regression fixture asserts no `pause requested`
command for either a logical-last-song bridge or the spent-original-to-outro
bridge. If Spotify has not yet published the next page, audio can still be
silent during the wait: this does not guarantee a gapless DJ transition.

Targeted-outro skip acknowledgement race: immediately after starting an unpaused
bridge, the core can still report the starting song at 0 s. The landing poll
now waits for a changed physical UID, a confirmed position reset, or a short
grace period before issuing an extra physical Next into the voice. The fixture
delays the targeted-skip acknowledgement beyond the first four polls to guard
against sending a spurious second skip.
