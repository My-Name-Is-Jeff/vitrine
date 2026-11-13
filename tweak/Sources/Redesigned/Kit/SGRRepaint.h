// The areas the redesign stripped and SGRRepaint.x keeps transparent when Spotify repaints them, each
// set by the part of the redesign that owns it.
#import <UIKit/UIKit.h>

extern __weak UIView *sgr_nowPlayingRoot;   // Redesigned/NowPlayingBar/NowPlayingBar.x, the bar
// Every view in the bar Spotify painted as a card, learned from the album-color paint, which goes clear. The bar
// makes the set and picks its card from it: in a Jam Spotify also paints the Jam strip, or a view around the
// strip and the track.
extern NSHashTable<UIView *> *sgr_nowPlayingPainted;
// Defined in Redesigned/NowPlayingBar/NowPlayingBar.x: the listener's round avatar on the Jam strip. Its fill
// is kept when the bar's paint goes clear, or only the initial is left.
BOOL SGRIsStripAvatar(UIView *view);
extern __weak UIView *sgr_lyricsPageRoot;   // Redesigned/Lyrics/LyricsPage.x
// Redesigned/Playlist/PlaylistField.x, the playlist page. Only the base surface Spotify paints the page,
// its list and its rows with goes clear here: the artwork field is underneath, and the grays of a
// placeholder or a badge are what still has to read against it.
extern __weak UIView *sgr_playlistRoot;
// Redesigned/Album/AlbumField.x, the album page, kept clear the same way and for the same reason.
extern __weak UIView *sgr_albumRoot;
// Redesigned/Artist/ArtistField.x, the artist page, kept clear the same way and for the same reason.
extern __weak UIView *sgr_artistRoot;
// Kit/SGRGlass.h's SGRGlassSheetChrome: the "sheet-view" pane it glassed (the ⋯ context menu, the queue,
// and the now-playing bar's pop-art track info, one component under all three). Any opaque fill its chrome
// repaints outside the sheet's own list (SGRIsSheetChromeArea) is cleared here on every repaint: Spotify
// draws it back on its own later, and a view built after the first pass is never stripped otherwise.
extern __weak UIView *sgr_sheetChromeRoot;
// That sheet watched from now on: its own layouts and those of the lists in it clear the grey Spotify paints on views
// it puts in later, before their first frame. Called by SGRGlassSheetChrome as it glasses the sheet.
void SGRWatchSheetPaint(UIView *root);

