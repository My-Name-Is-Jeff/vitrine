# Next DJ Set: skip-mode regression checks

Run `python3 harness/dj-next-segment/check.py`. The portable checks verify that
DJ queue and Next DJ Set button are on by default, the action row is
conditional on those switches, skip mode is the default, and skip mode never
sends a native jump or a text request. On macOS, the same command compiles the production
`isNewSegmentItem` predicate with Foundation fakes and verifies that old tracks,
queued tracks and delimiters cannot be mistaken for a new DJ page; a new page
can reuse an intro UID if its `page_instance_id` changed, and a genuinely
new UID can belong to a new segment even when Spotify retains the same page ID.
If the next page is not published after reaching the final track, a bounded
physical Next advances past the old song/outro, but never through a hand queue.

This is **not** a live playback test. Verify on Spotify 9.1.90 that the queue
button appears with Edit, leaves the current page without hearing its remaining
songs, plays the next page's intro, preserves the paused state if originally
paused, and times out gracefully if the DJ cannot produce a new page. Also
verify that the direct neutral request mode works and the untouched native
Let DJ pick still works independently. Skip uses only player pause/skip and
awaits the core's next segment; it sends no signal or suggested prompt.
