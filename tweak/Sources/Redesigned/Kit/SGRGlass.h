// Glass for the redesign's control layer, and only for it: never behind rows, cards or text. Built on
// Core/SGGlass.m (the effect made through +effectWithStyle:). Under Reduce Transparency a shape is a
// solid SGRSolidGlassFill, on any OS; before iOS 26 without it, a dark thin material blur. Nothing
// touches a glass class on an OS without them. A shape is dark whatever the system appearance: glass
// takes the one it inherits, which outside the navigation stacks Spotify makes dark (the player) is the
// system's, light on a phone in light mode.
//
// Ownership: a shape belongs to the control it is made in (associated with it under the caller's key).
// Threading: main thread only.
#import <UIKit/UIKit.h>

// A glass circle inside someone else's round control, `side` across, behind everything the control
// draws (first in its subviews, re-asserted on every call, since glass takes what is above it in the
// tree into its backdrop however the depths are set) and kept at its middle by the autoresizing mask.
// Being the control's own
// subview it goes wherever the control goes: a frame worked out from outside goes stale when Spotify
// lays a row out after the unit that holds it (the player's header circles sat 24pt off until a tap
// laid the unit out again, trees/continuous/1.txt 2026-09-17). Takes no touches; made once per control
// under `key`, and made again when Reduce Transparency changes the kind of shape.
UIView *SGRGlassInside(UIView *control, const void *key, CGFloat side);

// The same, in a capsule `size` across rather than a circle: for the one control of an action row that
// leads (the playlist header's Play). `prominent` lays a white film inside the shape, so that control
// reads a step brighter than the circles beside it without leaving the same material.
UIView *SGRGlassCapsuleInside(UIView *control, const void *key, CGSize size, BOOL prominent);

// Shows or hides a shape of the Kit's by its effect, never by an alpha on it or on a view above it
// (Redesigned/Player/PlayerMotion.x): UIKit draws the material wrongly or not at all under a fading alpha.
// The solid shape Reduce Transparency puts in its place has no effect and fades by its own alpha. Animates
// in the caller's animation.
void SGRShowGlass(UIView *shape, BOOL shown);

// The faint white film over a floating bar's glass (the tab bar's platter, the now playing card), without
// which the bar disappears into Spotify's near-black chrome. Made once under `key`, kept just above `glass`
// and on its frame, with corners of `radius`. Nil on iOS 26, where the system glass needs none.
UIView *SGRGlassFilm(UIView *host, const void *key, UIView *glass, CGFloat radius);

// How much floating glass is dimmed (SGRDarkenGlass): what Create's menu dims the page behind the tab bar by, under
// which the bar read best.
extern const CGFloat SGRBarDim;
// A black layer of `alpha` inside `pane` (a legacy glass pane or a blur), made once under `key`: over what the glass
// shows of the page, under its rim, its film and what stands on it, so the controls on floating glass (the tab bar,
// the now playing card, the top buttons, the toast) stand out over a bright page. Corners of `radius`. Nil on iOS 26.
UIView *SGRDarkenGlass(UIView *pane, const void *key, CGFloat radius, CGFloat alpha);

