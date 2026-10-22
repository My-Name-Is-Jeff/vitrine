// What the lines mean: Genius's annotations on the song, matched by their text to the lines the
// lyrics view shows, whichever source those came from. Genius's own web endpoints, which take no key.
#import <UIKit/UIKit.h>
#import "Shared/Lyrics/Lyrics.h"

// Whose annotations show, as SGLyricsMeaningsLevel; unset is off.
#define SGKeyLyricsMeanings @"spotifyglass.lyricsMeanings"

typedef NS_ENUM(NSInteger, SGLyricsMeaningsLevel) {
    SGLyricsMeaningsOff = 0,
    SGLyricsMeaningsArtist,    // written or verified by the artist
    SGLyricsMeaningsEditors,   // and the ones Genius's editors accepted
    SGLyricsMeaningsAll,       // and the community's not yet reviewed
};

// Ordered as they are listed, the artist's first.
typedef NS_ENUM(NSUInteger, SGLyricsMeaningAuthor) {
    SGLyricsMeaningByArtist = 0,
    SGLyricsMeaningByEditors,
    SGLyricsMeaningByCommunity,
};

@interface SGLyricsMeaning : NSObject
@property (nonatomic, copy) NSString *fragment;   // the words it explains, as Genius has them
@property (nonatomic, copy) NSString *body;
@property (nonatomic) SGLyricsMeaningAuthor author;
@property (nonatomic, copy) NSString *url;
@end

SGLyricsMeaningsLevel SGLyricsMeaningsShown(void);
@class SGModRow;
SGModRow *SGLyricsMeaningsRow(void);

// The meanings of the lines by index into `lines`, on the main queue: empty when Genius has none for
// the song or it could not be told apart, never called while the setting is off. Genius is asked once
// per track; the matching is done again for each set of lines.
void SGLyricsMeaningsFor(NSString *trackID, NSArray<SGKaraokeLine *> *lines,
                         void (^done)(NSDictionary<NSNumber *, NSArray<SGLyricsMeaning *> *> *byLine));

// Genius's search, which the lyrics source asks too (Shared/LyricsSources/Genius.m): its address, what
// it is asked for a track, and the song in its reply that is the track, as SGLyricsSongRank
// (Shared/LyricsSources/SongMatch.m) tells: of several, the same version wins, then the plain song.
// nil when none is, or the track is an instrumental or karaoke version, since Genius files the words
// under the song.
#define SGGeniusSearchURL @"https://genius.com/api/search/song"
NSDictionary<NSString *, NSString *> *SGGeniusSearchQuery(NSString *title, NSString *artist);
NSNumber *SGGeniusSongIn(NSDictionary *response, NSString *title, NSString *artist);
