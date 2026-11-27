# PR #227 — `getState` cap behavior and measurement

## Why the context-free subscription is not gated on the current track

The queue needs enough future tracks to populate an AI DJ segment (up to 16
requested, though the core can return fewer). `ESPContextPlayerClientImpl
getState:onResponse:` also receives a **context-free, long-lived subscription**
created before Spotify selects any playback context. The subscription remains
active when the user later starts the DJ. Limiting that request according to
*the context currently playing* would bake the ordinary cap into the subscription
and risk leaving a later DJ session with too few tracks. Requests bearing an
explicit non-DJ `contextURI` already retain Spotify's original cap.

No safe subscription replacement or dynamic resubscription mechanism has been
verified for Spotify 9.1.90. Until one is established on a device, the context-
free subscription still requests 16 next and 16 previous tracks. This is a
**deliberate compatibility limitation**, not a claim that non-DJ behavior is
fully unchanged. The extra data must be measured and disclosed to the reviewer.

## Simulator A/B result — 20 November 2026

The user recorded matching roughly one-minute non-DJ playback runs with the
DJ Queue setting enabled and disabled and supplied `dj-cap-comparison.json`.
The script returned `comparison.valid=true`; values below are **sampled
player-state occupancy**, not transport-level request measurements.

| | Enabled | Disabled | Difference |
|---|---:|---:|---:|
| Duration | 59.59 s | 59.61 s | — |
| Polls | 74 | 75 | — |
| Distinct state signatures | 1 | 1 | — |
| Future-track references, average/peak | 16 / 16 | 2 / 2 | **+14** |
| Additional previous-track references | 10 | 0 | **+10** |

Thus the observed non-DJ player state holds **24 additional track references**
relative to the setting-off control: 14 future and 10 previous. This is a
real change to ordinary playback state, not a negligible zero-overhead claim.
The extra references *can* increase state size and processing work, but the
sample does not quantify memory bytes, CPU time, network traffic or energy.
These repeated polls describe one unchanged state, not 74 ESP responses.

The callback's context-free subscription is initialized before the player has
selected a context, and Spotify 9.1.90 does not provide a verified, safe way
for this tweak to refresh that subscription when DJ begins. Using the current
context to lower its cap may permanently deprive DJ of upcoming tracks in
that session. Requests with an **explicit non-DJ context** already pass the
original caps through. This remaining context-free exception is deliberate,
measured as far as the exposed player-state data permits, and should be
reviewed with the PR owner rather than hidden behind a claim of isolation.

A true allocation/time/network cost benchmark would require an instrumented
pair of matching device runs (e.g., Instruments Allocations and Time Profiler,
plus an ESP request/response-size probe). No such measurements are available;
we must not invent them.

## Reproducing the measurement

In a debug/FLEX build with `SG_DRIVER=1`, capture the future and reverse
arrays of a stable ordinary-playlist `SPTPlayerState` every second for a minute;
repeat with the DJ Queue switch disabled and Spotify restarted. Compare the
number of distinct state signatures, next/previous-track references and the
excess over the setting-off baseline. Never multiply repeated snapshots by the
reference difference to infer bytes or request rates. Before PR merge, the
one-off `dj-cap-*` scripts and their driver endpoints are removed; the
anonymized summary above remains as review evidence.

## Next DJ Set UI clarification for the PR response

In the tested Spotify UI, **both the native Edit and the Vitrine Next DJ Set
button are flat capsules**. The Native and Redesigned implementations have
already been separated. Changing only Next DJ Set to a glass button would
create a visual mismatch rather than fix one; no UI-material change is needed.
