// AnimatedArtwork.h
#import <UIKit/UIKit.h>

#define SGKeyLockScreenArtwork @"spotifyglass.lockscreen.artwork"
#define SGKeyLockScreenMotion @"spotifyglass.lockscreen.motion"
#define SGKeyLockScreenLyricsStyle @"spotifyglass.lockscreen.lyricsStyle"
#define SGKeyMotionLowData @"spotifyglass.motion.lowdata"
#define SGKeyMotionSources @"spotifyglass.motion.sources"

typedef NS_ENUM(NSInteger, SGLockArtwork) {
    SGLockArtworkOff = 0,
    SGLockArtworkMotion,   // the Canvas, else Apple Music's animated cover (LockScreenMotion.x)
    SGLockArtworkLyrics,   // a clip per line of lyrics (Shared/LockScreenLyrics/LyricsArtwork.x)
    SGLockArtworkEverySong,   // Moving artwork, else the cover over a moving blur of it (LockScreenMotion.x)
    // The lyrics over the moving artwork, else Lyrics: LockScreenMotion.x finds the clip, LyricsArtwork.x
    // draws the lines over it.
    SGLockArtworkMotionLyrics,
};
// Off below iOS 26, which has no animated artwork on the lock screen.
SGLockArtwork SGLockScreenArtwork(void);
// Under Moving artwork with lyrics, LyricsArtwork.x says whether the playing track has no synced lines (YES), so
// LockScreenMotion.x shows its moving artwork plain, as Moving artwork does, or has them (NO), so it takes it off
// for the lyrics' clips. Main queue.
void SGLockMotionShowPlain(BOOL plain);
static inline BOOL SGLockArtworkShowsLyrics(SGLockArtwork artwork) {
    return artwork == SGLockArtworkLyrics || artwork == SGLockArtworkMotionLyrics;
}
// How the lyrics are drawn, stored as the index of SGLyricsClipStyle (Still unless changed).
#define SGKeyLockScreenLyricsStyle @"spotifyglass.lockscreen.lyricsStyle"
// Off until switched on: the lock screen widget's star switches the choice between a choice with lyrics and
// one without (LockScreenStar.x), and takes the place of Spotify's like and dislike buttons. StarBack is the
// choice the star left, to go back to.
#define SGKeyLockScreenStar @"spotifyglass.lockscreen.star"
#define SGKeyLockScreenStarBack @"spotifyglass.lockscreen.star.back"
// Off until switched on: download in Low Data Mode too.
#define SGKeyMotionLowData @"spotifyglass.motion.lowdata"

typedef NS_ENUM(NSInteger, SGMotionShape) {
    SGMotionSquare,
    SGMotionTall,
};

SGLockArtwork SGLockScreenArtwork(void);

void SGMotionAlbumCover(NSString *artist, NSString *album, SGMotionShape shape, CGFloat pixels, void (^done)(NSURL *file));
void SGMotionArtistLogo(NSString *artist, CGFloat pixels, void (^done)(UIImage *logo));
CGFloat SGMotionPixels(void);
void SGMotionSongsWithISRC(NSString *isrc, void (^done)(NSArray *songs));

NSArray<NSString *> *SGMotionSourceOrder(void);
BOOL SGMotionAppleMusicOn(void);
NSURL *SGMotionCanvasIn(NSDictionary *metadata);
void SGMotionClipFor(NSString *uri, NSURL *canvas, NSString *artist, NSString *album, SGMotionShape shape, CGFloat pixels, void (^done)(NSURL *file, NSString *source));

@class SPTPlayerState;
@interface SGMotionFollower : NSObject
- (instancetype)initWithBegin:(BOOL (^)(NSString *uri, SPTPlayerState *state))begin
                        found:(void (^)(NSString *uri, NSURL *file))found;
- (void)restart;
@end

@class SGModRow;
SGModRow *SGMotionSourcesRow(void);

void SGMotionFile(NSURL *remote, void (^done)(NSURL *file));
NSURL *SGMotionMadeFile(NSString *key);
void SGMotionPoster(NSURL *file, void (^done)(UIImage *poster));

NSArray *SGLockScreenMotionRows(void);
SGModRow *SGLockScreenArtworkNeedsRow(void);

NSString *SGMotionNameKey(NSString *name);
NSString *SGMotionSearchName(NSString *name);
NSString *SGMotionStreamIn(NSString *master, CGFloat pixels);
NSString *SGMotionWholeFileIn(NSString *media);
