# Lyrics walk check

`./build.sh` checks, on the Mac as a Mac Catalyst binary, with no simulator and no network, the walk down
the sources' order (`Shared/LyricsSources/LyricsSources.m`) and a source picked for a track from the
redesigned player's ⋯ (`LyricsPick.m`, issue #67). Every source is answered by the check itself, by key:

- the walk stops at the order's first timed answer, which is nobody's pick;
- a pick keeps the source's answer as the track's, marked as the pick's, and shows it;
- a later walk, once the walk's answers have been forgotten (40 tracks), asks the pick first and keeps
  its lines as the pick's; with the pick's request failing, the pick stands and the walk's answer is kept
  as the order's, not the pick's, and the next walk asks the pick again; with the pick answering nothing,
  the pick is dropped.

It does not cover the sources' own requests, Spotify's own lines weighed against the walk's (LyricsHook.x),
or the menu.
