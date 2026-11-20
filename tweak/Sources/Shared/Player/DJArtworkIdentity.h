// Identify the actual Spotify AI DJ card, not a user playlist called "DJ".
#import <UIKit/UIKit.h>
BOOL SGDJArtworkIsConfirmedCard(UIView *card);

// Conservative fallback for a Spotify-published DJ card: refuse user playlist
// publishers even when their title is DJ and their bitmap is missing. Native
// artwork (UIImageView or layer contents) still wins. *retry schedules redraw.
BOOL SGDJArtworkNeedsPlaceholder(UIView *card, UIView *holder, BOOL *retry);

// Cache the nearest Home/Recents card, invalidating it when the image holder
// moves under a different card even if the immediate parent stays unchanged.
UIView *SGDJArtworkEnclosingCard(UIView *holder);
