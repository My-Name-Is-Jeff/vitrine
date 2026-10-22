// A source picked for one track (issue #67). The walk stops at the first source with timed lyrics, so a source
// lower in the order that has the song better timed is never asked; the redesigned player's ⋯ asks them all for
// the track playing, lists the ones with lines, and keeps the one picked as the track's lyrics.
#import "Core/SGCore.h"
#import "LyricsSources.h"
#import "Shared/Lyrics/Lyrics.h"

NSNotificationName const SGLyricsSourceChosenNotification = @"spotifyglass.lyricsSourceChosen";

// Each track's asks are kept for the menu opened on it again; the picks are kept for the replays.
static const NSUInteger kAskedTracks = 10, kChosenTracks = 200;

// Every source asked for one track, and who waits for them all.
@interface SGLyricsOfferAsk : NSObject
@property (nonatomic, copy) NSArray<NSString *> *order;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *answers;   // a result with lines, else NSNull
@property (nonatomic, strong) NSMutableArray<void (^)(void)> *waiting;
@end

@implementation SGLyricsOfferAsk
@end

static NSMutableDictionary<NSString *, SGLyricsOfferAsk *> *sg_asks;
static NSMutableDictionary<NSString *, NSString *> *sg_chosen;

NSString *SGLyricsChosenSource(NSString *trackID) {
    return trackID ? sg_chosen[trackID] : nil;
}

static NSDictionary<NSString *, SGLyricsResult *> *offersIn(SGLyricsOfferAsk *ask) {
    NSMutableDictionary<NSString *, SGLyricsResult *> *offers = [NSMutableDictionary dictionary];
    [ask.answers enumerateKeysAndObjectsUsingBlock:^(NSString *key, id answer, BOOL *stop) {
        if (answer != NSNull.null) offers[key] = answer;
    }];
    return offers;
}

static void answer(SGLyricsOfferAsk *ask, NSString *key, SGLyricsResult *result) {
    ask.answers[key] = result.karaokeLines.count ? result : NSNull.null;
    if (ask.answers.count < ask.order.count) return;
    NSArray *waiting = ask.waiting;
    ask.waiting = nil;
    for (void (^done)(void) in waiting) done();
}

static SGLyricsOfferAsk *askAll(NSString *trackID) {
    SGLyricsOfferAsk *ask = [SGLyricsOfferAsk new];
    ask.order = SGLyricsOrder();
    ask.answers = [NSMutableDictionary dictionary];
    ask.waiting = [NSMutableArray array];
    SGLyricsQuery *named = SGLyricsQueryFor(trackID);
    SGLog(@"lyrics: asking %@ at once for %@, for the player's ⋯", [ask.order componentsJoinedByString:@", "], trackID);
    for (NSString *key in ask.order) {
        SGLyricsProvider *provider = SGLyricsProviderFor(key);
        // A query each, so what one source learns does not change what the next is asked.
        SGLyricsQuery *query = SGLyricsQueryFor(trackID);
        if (provider.needsName && !(named.title.length && named.artist.length)) {
            answer(ask, key, nil);
            continue;
        }
        provider.ask(query, ^(SGLyricsResult *result) {
            if (result.karaokeLines.count && !result.provider) result.provider = provider.name;
            SGLog(@"lyrics: %@ offers %lu lines for %@", key, (unsigned long)result.karaokeLines.count, trackID);
            answer(ask, key, result);
        });
    }
    return ask;
}

void SGLyricsOffers(NSString *trackID, NSTimeInterval wait, void (^done)(NSDictionary<NSString *, SGLyricsResult *> *offers)) {
    if (!sg_asks) sg_asks = [NSMutableDictionary dictionary];
    SGLyricsOfferAsk *ask = sg_asks[trackID];
    if (!ask) {
        if (sg_asks.count >= kAskedTracks) [sg_asks removeAllObjects];
        ask = sg_asks[trackID] = askAll(trackID);
    }
    __block BOOL called = NO;
    void (^once)(void) = ^{
        if (called) return;
        called = YES;
        done(offersIn(ask));
    };
    if (!ask.waiting) {
        once();
        return;
    }
    [ask.waiting addObject:once];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), once);
}

void SGLyricsChooseSource(NSString *trackID, NSString *key) {
    id result = sg_asks[trackID].answers[key];
    if (![result isKindOfClass:SGLyricsResult.class]) return;
    SGLyricsResult *lyrics = result;
    if (!sg_chosen) sg_chosen = [NSMutableDictionary dictionary];
    if (sg_chosen.count >= kChosenTracks) [sg_chosen removeAllObjects];
    sg_chosen[trackID] = key;
    SGLog(@"lyrics: %@ picked for %@, %lu lines", key, trackID, (unsigned long)lyrics.karaokeLines.count);
    SGLyricsKeepChosen(trackID, lyrics);
    // The credit before the lines, which the lyrics page asks for once it has them.
    SGLyricsSetCredit(trackID, lyrics.provider);
    SGKaraokeKeepLines(trackID, lyrics.karaokeLines);
    // Queued behind the keep above, so a page that drops its lines on this finds the new ones kept.
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsSourceChosenNotification object:trackID];
    });
}
