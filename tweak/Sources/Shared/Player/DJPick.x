// Next DJ Set's optional request action uses the native 9.1.90 suggested-prompt
// payload directly. No native DJ button or CompositeJumpable is hooked, and no
// preliminary "jump" signal is sent. A new DJ landing, not local acceptance,
// completes the request and resets the custom queue's previous segment order.
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/AdBlock/Protobuf.h"
#import "DJQueue.h"
#import "DJPick.h"
#import "PlayerState.h"
#import <objc/message.h>

static const NSTimeInterval kDJPromptTimeout = 20;
static NSString *DJPickContext(SPTPlayerState *state) {
    NSString *uri = SGURIString(state.contextURI);
    if ([uri isEqualToString:@"spotify:playlist:37i9dQZF1EYkqdzj48dyYq"] ||
        ([uri hasPrefix:@"spotify:playlist:"] && state.track.metadata[@"segment"])) return uri;
    return nil;
}
static NSString *DJPickPrompt(void) {
    // Spotify 9.1.90's own suggested request: protobuf field 1 is the English
    // prompt; field 2 is 3 (suggested request), base64 in ESPSignalRequest.
    NSData *body = SGPBSerialize(@[SGPBString(1, @"Surprise me with a new mix based on my taste."), SGPBVarint(2, 3)]);
    return [body base64EncodedStringWithOptions:0];
}
static NSError *DJPickError(NSString *detail) {
    return [NSError errorWithDomain:@"dev.vitrine.dj-pick" code:1 userInfo:@{NSLocalizedDescriptionKey: detail}];
}

@interface SGDJPickAttempt : NSObject
@property id player;
@property NSString *context, *URI, *UID, *page, *interaction;
@property NSTimeInterval started;
@property BOOL finished, paused;
@property NSTimer *timer;
@property NSMutableArray *completions;
- (void)pollAt:(NSTimeInterval)now;
- (void)finish:(NSError *)error changed:(BOOL)changed;
@end
static SGDJPickAttempt *sDJPickAttempt;

@implementation SGDJPickAttempt
- (void)finish:(NSError *)error changed:(BOOL)changed {
    if (self.finished) return;
    self.finished = YES;
    [self.timer invalidate]; self.timer = nil;
    if (sDJPickAttempt == self) sDJPickAttempt = nil;
    SGDJQueueFinishPick(changed);
    NSArray *callbacks = [self.completions copy];
    [self.completions removeAllObjects];
    for (void (^callback)(NSError *) in callbacks) callback(error);
}
- (void)pollAt:(NSTimeInterval)now {
    if (self.finished) return;
    SPTPlayerState *state = [(id<SPTPlayer>)self.player state];
    if (![DJPickContext(state) isEqualToString:self.context]) {
        [self finish:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil] changed:NO];
        return;
    }
    BOOL same = [SGURIString(state.track.URI) isEqualToString:self.URI] &&
                [state.track.UID ?: @"" isEqualToString:self.UID];
    BOOL samePage = self.page.length && [state.track.metadata[@"page_instance_id"] isEqualToString:self.page];
    if (self.interaction.length && state.track.metadata[@"interaction_id"] &&
        ![state.track.metadata[@"interaction_id"] isEqualToString:self.interaction]) samePage = NO;
    BOOL queued = [state.track.provider isEqualToString:@"queue"] || [state.track.UID hasPrefix:@"q"];
    if (!same && !samePage && !queued) {
        SGLog(@"DJ pick: confirmed neutral request landing on %@ [%@]", state.track.URI, state.track.UID);
        [self finish:nil changed:YES];
        return;
    }
    // A user pause ends pending request tracking instead of silently waiting.
    if (!self.paused && state.isPaused) { [self finish:nil changed:NO]; return; }
    if (now - self.started >= kDJPromptTimeout)
        [self finish:DJPickError(@"DJ did not start a new set. Please try again.") changed:NO];
}
@end

void SGDJPickRequest(id player, void (^completion)(NSError *error)) {
    // Queue actions normally arrive on main; keep timer and queue UI changes
    // on main even if a caller uses the public entry from another queue.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGDJPickRequest(player, completion); });
        return;
    }
    SEL signal = NSSelectorFromString(@"signal:parameters:options:loggingParams:");
    SPTPlayerState *state = [player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil;
    SEL signals = NSSelectorFromString(@"signals");
    id supported = [state respondsToSelector:signals] ? ((id (*)(id, SEL))objc_msgSend)(state, signals) : nil;
    NSString *context = DJPickContext(state);
    if (!context || !state.track || ![player respondsToSelector:signal] ||
        ![supported respondsToSelector:@selector(containsObject:)] || ![supported containsObject:@"prompt"]) {
        SGLog(@"DJ pick: neutral suggested request unavailable (context=%@)", context);
        if (completion) completion(DJPickError(@"DJ isn't ready to accept a request right now."));
        return;
    }
    if (sDJPickAttempt) {
        if (sDJPickAttempt.player == player && [sDJPickAttempt.context isEqualToString:context]) {
            if (completion) [sDJPickAttempt.completions addObject:[completion copy]];
            return;
        }
        [sDJPickAttempt finish:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil] changed:NO];
    }
    SGDJPickAttempt *attempt = [SGDJPickAttempt new];
    attempt.player = player;
    attempt.context = context;
    attempt.URI = SGURIString(state.track.URI) ?: @"";
    attempt.UID = state.track.UID ?: @"";
    attempt.page = state.track.metadata[@"page_instance_id"];
    attempt.interaction = state.track.metadata[@"interaction_id"];
    attempt.paused = state.isPaused;
    attempt.started = CACurrentMediaTime();
    attempt.completions = [NSMutableArray array];
    if (completion) [attempt.completions addObject:[completion copy]];
    sDJPickAttempt = attempt;
    SGDJQueueBeginPick();
    __weak SGDJPickAttempt *weak = attempt;
    attempt.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        SGDJPickAttempt *strong = weak;
        if (!strong) { [timer invalidate]; return; }
        [strong pollAt:CACurrentMediaTime()];
    }];
    [NSRunLoop.mainRunLoop addTimer:attempt.timer forMode:NSRunLoopCommonModes];
    SGLog(@"DJ pick: requesting one neutral suggested prompt directly (no native jump)");
    @try {
        ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(player, signal, @"prompt", DJPickPrompt(), nil, nil);
    } @catch (NSException *exception) {
        SGLog(@"DJ pick: neutral request raised %@", exception.reason);
        [attempt finish:DJPickError(@"DJ couldn't send the request. Please try again.") changed:NO];
    }
}
