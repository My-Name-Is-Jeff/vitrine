// The AI DJ's tracks to come on Spotify's queue page, to reorder and remove (DJQueue.x). Either look.
#import <Foundation/Foundation.h>

#define SGKeyDJQueue @"spotifyglass.djqueue"   // on until switched off; read at launch
#define SGKeyDJQueuePickButton @"spotifyglass.djqueue.pickButton" // live, on by default
#define SGKeyDJQueueSetMode @"spotifyglass.djqueue.setMode" // live; exactly one action
#define SGDJQueueSetModeSkip 0    // default: skip the current DJ page without a request
#define SGDJQueueSetModeRequest 1 // direct neutral suggested prompt (no native jump)
// The DJ's session as the user left it (order, removed, played), so a launch in the same session goes on with it.
#define SGKeyDJQueueSession @"spotifyglass.djqueue.session"

// A native DJ Pick is also a set change for a custom queue. Keep its order
// inactive while the service is working, and discard it only on an actual landing.
void SGDJQueueBeginPick(void);
void SGDJQueueFinishPick(BOOL changed);
