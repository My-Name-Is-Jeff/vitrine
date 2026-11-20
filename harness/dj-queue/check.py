#!/usr/bin/env python3
"""Compile the production DJ history and end-of-track decisions against small Foundation fakes."""
from pathlib import Path
import subprocess, tempfile
queue_path = Path(__file__).resolve().parents[2] / 'tweak/Sources/Shared/Player/DJQueue.x'
import re
source = re.sub(r'^#include "(DJQueue[^"]+\.inc)"$',
                lambda m: (queue_path.parent / m.group(1)).read_text(),
                queue_path.read_text(), flags=re.M)
def function(name):
    import re
    match = re.search(r'^[A-Za-z_][^\n]*\b' + name + r'\([^\n]*\) \{', source, re.M)
    assert match, name
    start = match.start(); pos = match.end(); depth = 1
    while depth:
        if source[pos] == '{': depth += 1
        if source[pos] == '}': depth -= 1
        pos += 1
    return source[start:pos]
prelude = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#import <dispatch/dispatch.h>
@interface SPTPlayerTrack : NSObject
@property NSString *URI, *UID, *provider;
@property NSDictionary *metadata;
@end
@implementation SPTPlayerTrack @end
@interface SPTPlayerState : NSObject
@property SPTPlayerTrack *track;
@property NSArray<SPTPlayerTrack *> *future, *reverse;
@property NSString *contextURI;
@property BOOL isPaused;
@property double position;
@end
@implementation SPTPlayerState @end
static NSString *SGURIString(id value) { return value; }
static NSString *kCardSuffix = @"-card";
static NSMutableDictionary *sCopyOf;
static void reconcilePendingCopies(SPTPlayerState *state) { (void)state; }
static NSMutableArray<SPTPlayerTrack *> *sPlayed;
static NSMutableSet *sHidden, *sPassed, *sPlayedBefore, *sVoiced;
static BOOL sDJActive = YES, sOrdered, sHandingOver, sAdvancing, sPlayingMoved;
static SPTPlayerTrack *wanted, *sAheadQueued;
static SPTPlayerTrack *lastOfSegment(SPTPlayerState *state);
static BOOL isDJSession(SPTPlayerState *state) { return YES; }
static SPTPlayerTrack *wantedNext(void) { return wanted; }
static SPTPlayerTrack *originalOf(SPTPlayerTrack *track) { return track; }
'''
names = ['baseUID','historyUID','sameGroup','isDJTrack','inDJ','isHidden','wasPlayed','staysHidden','playedIndex','playedBefore','playedAfter','historyFutureRows','isCoreQueued','queuedCopyOf','coreNextUnplayed','isUnspent','reachableInFuture','skipPastSpent','repeatedCurrentOutro','onlyThisLeft','lastLogicalNext']
tests = r'''
static SPTPlayerTrack *song(NSString *uid) {
    SPTPlayerTrack *t = [SPTPlayerTrack new]; t.UID = uid;
    t.URI = [@"spotify:track:" stringByAppendingString:uid];
    t.provider = @"context"; t.metadata = @{@"page_instance_id": @"segment"}; return t;
}
int main(void) { @autoreleasepool {
    SPTPlayerTrack *one = song(@"1"), *two = song(@"2"), *three = song(@"3"), *four = song(@"4"), *five = song(@"5");
    SPTPlayerTrack *copy = song(@"q3"); copy.URI = three.URI; copy.provider = @"queue";
    sCopyOf = [@{@"q3": @{@"uid": @"3", @"uri": three.URI}} mutableCopy];
    sPlayed = [@[one,two,three,four,five] mutableCopy];
    sHidden = [NSMutableSet setWithArray:@[@"2",@"3",@"4"]];
    sPassed = [NSMutableSet setWithArray:@[@"2",@"4"]];
    sPlayedBefore = [NSMutableSet set]; sVoiced = [NSMutableSet set];
    SPTPlayerState *state = [SPTPlayerState new]; state.reverse = @[one,copy]; state.track = five;
    assert(playedBefore(state) == four); state.track = four;
    assert(playedBefore(state) == copy); state.track = copy;
    assert(playedBefore(state) == two); state.track = two;
    assert(playedBefore(state) == one); state.track = one;
    assert(playedBefore(state) == nil);
    // A removed song is skipped, while rows passed by a tap remain navigable.
    [sPassed removeObject:@"4"]; state.track = five;
    assert(playedBefore(state) == copy); [sPassed addObject:@"4"];
    assert(playedAfter(copy) == four);
    state.track = three; assert(([historyFutureRows(state) isEqualToArray:@[four,five]]));
    state.track = copy; assert(([historyFutureRows(state) isEqualToArray:@[four,five]]));
    state.track = one; assert(([historyFutureRows(state) isEqualToArray:@[two,three,four,five]]));
    [sPassed removeObject:@"4"]; assert(([historyFutureRows(state) isEqualToArray:@[two,three,five]])); [sPassed addObject:@"4"];
    state.track = five; assert(historyFutureRows(state).count == 0);
    assert(!staysHidden(three));
    // A hand-queued duplicate of a DJ track is not a copy owned by Vitrine.
    SPTPlayerTrack *manual = song(@"qManual"); manual.URI = three.URI; manual.provider = @"queue";
    state.future = @[manual, copy];
    assert(queuedCopyOf(three, state, NULL) == copy);
    state.future = @[manual]; assert(queuedCopyOf(three, state, NULL) == nil);
    state.future = @[copy, manual]; BOOL hasManualAfter = NO;
    assert(queuedCopyOf(three, state, &hasManualAfter) == copy && hasManualAfter);
    // Last reordered track: its stale context next must be skipped before it sounds.
    state.track = five; SPTPlayerTrack *fresh = song(@"6"); state.future = @[three,fresh];
    sOrdered = YES; assert(skipPastSpent(state) == fresh);
    // Same-uid outro after a duplicate is a different physical item, not the current song.
    SPTPlayerTrack *outro = song(@"5"); outro.URI = @"spotify:media:5";
    state.future = @[five,outro,fresh]; assert(repeatedCurrentOutro(state) == outro);
    state.future = @[outro,fresh]; assert(repeatedCurrentOutro(state) == nil);
    state.track = three; state.future = @[three,outro,fresh]; assert(repeatedCurrentOutro(state) == nil);
    state.track = five; state.future = @[three,fresh];
    // Same decision when the last track itself is a queue copy.
    SPTPlayerTrack *copyFive = song(@"q5"); copyFive.URI = five.URI; copyFive.provider = @"queue";
    sCopyOf[@"q5"] = @{@"uid":@"5", @"uri":five.URI}; state.track = copyFive;
    assert(skipPastSpent(state) == fresh);
    // A known q-UID copy of the current song is already spent even though
    // isUnspent(copyFive) sees its distinct q-UID as not played.
    state.track = five; state.future = @[copyFive,outro,fresh]; assert(repeatedCurrentOutro(state) == outro);
    // A different known queued copy must not be crossed just to reach the voice.
    state.future = @[copy,outro,fresh]; assert(repeatedCurrentOutro(state) == nil);
    state.future = @[three,fresh];
    // After reorder: the current physical-last song played through a queue
    // copy, but a different already-played context song comes before its outro.
    SPTPlayerTrack *spent = song(@"2");
    state.track = copyFive; state.future = @[spent,five,outro,fresh];
    assert(repeatedCurrentOutro(state) == outro);
    // Keep ordinary tracks, user's queued items, and the intended DJ order.
    sPlayed = [@[one,three,four,five] mutableCopy]; [sHidden removeObject:@"2"];
    assert(repeatedCurrentOutro(state) == nil); // '2' has not played or been hidden
    [sHidden addObject:@"2"];
    assert(repeatedCurrentOutro(state) == outro); // deliberately removed is spent
    sPlayed = [@[one,two,three,four,five] mutableCopy];
    SPTPlayerTrack *handAtOutro = song(@"qHand"); handAtOutro.provider = @"queue";
    state.future = @[handAtOutro,five,outro,fresh]; assert(repeatedCurrentOutro(state) == nil);
    state.future = @[spent,five,outro,fresh]; wanted = fresh; sOrdered = YES;
    assert(repeatedCurrentOutro(state) == nil); wanted = nil;
    state.future = @[outro,fresh]; assert(repeatedCurrentOutro(state) == nil); // natural outro
    state.future = @[spent,five,outro,fresh]; assert(repeatedCurrentOutro(state) == outro);
    state.track = five; state.future = @[three,fresh];
    // Preserve an intentional walk forwards through history and tracks queued by hand.
    state.track = copy; assert(skipPastSpent(state) == nil);
    state.track = five; wanted = fresh; assert(skipPastSpent(state) == fresh); wanted = song(@"not-reachable"); assert(skipPastSpent(state) == nil); wanted = nil;
    SPTPlayerTrack *hand = song(@"qHand"); hand.provider = @"queue";
    state.future = @[hand,three,fresh]; assert(skipPastSpent(state) == nil);
    // An already queued logical last song still needs the physical context anchor.
    sPlayed = [@[four,five,one,two] mutableCopy]; [sHidden removeObject:@"3"];
    state.track = two; state.future = @[copy,three,four,five,outro]; sAheadQueued = wanted = three;
    assert(onlyThisLeft(state, three)); assert(lastLogicalNext(state) == three);
    state.future = @[three,four,five,outro]; assert(lastLogicalNext(state) == three);
    state.future = @[copy,three,four,five,outro];
    // A queue copy of the physical last is not proof that the core reached that last item.
    sPlayed = [@[four,one,two,five] mutableCopy]; state.track = copyFive;
    assert(onlyThisLeft(state, three)); assert(lastLogicalNext(state) == three);
    state.future = @[hand,copy,three,four,five,outro]; assert(lastLogicalNext(state) == nil);
    sPlayed = [@[one,two,three,four,five] mutableCopy]; sAheadQueued = wanted = nil;
    puts("DJ history and spent-track decisions: PASS");
} }
'''
with tempfile.TemporaryDirectory(prefix='vitrine-dj-check-') as tmp:
    path = Path(tmp) / 'check.m'
    saved_source = source
    source = (Path(__file__).resolve().parents[2] / 'tweak/Sources/Shared/Player/SpeedPitch.x').read_text()
    mute_code = r'''
#import <stdatomic.h>
typedef uint32_t AudioUnitRenderActionFlags;
typedef struct { uint32_t mNumberChannels, mDataByteSize; void *mData; } AudioBuffer;
typedef struct { uint32_t mNumberBuffers; AudioBuffer mBuffers[2]; } AudioBufferList;
#define kAudioUnitRenderAction_OutputIsSilence 1
#import <mach/mach_time.h>
static atomic_bool sg_djTransitionMuted;
static atomic_uint_fast64_t sg_djMuteDeadline;
static atomic_uint_fast64_t sg_djMutedBuffers;
static const double kDJMuteMaxSeconds = 12;
''' + function('SGPlayerSetDJTransitionMuted') + function('djMuteActive') + function('SGPlayerDJTransitionMuted') + function('muteDJTransition')
    source = saved_source
    handover = mute_code + r'''
@protocol SPTPlayer <NSObject>
- (id)pause:(id)options;
- (id)resume:(id)options;
@end
static SPTPlayerState *testState;
static SPTPlayerTrack *landingTarget;
static SPTPlayerTrack *nextPhysicalSong, *prefetchedNext;
static NSUInteger queueCalls;
static NSMutableArray *commands;
static double skipAcknowledgementDelay = .08;
static NSUInteger sUserPauseRevision, sLandingPauseRevision;
static BOOL sInternalDJPause;
static void pauseForDJTransition(id<SPTPlayer> player) { sInternalDJPause = YES; [player pause:nil]; sInternalDJPause = NO; }
static NSString *sHandOverAnchorUID;
static SPTPlayerTrack *sHandOverDisplayTrack;
static SPTPlayerState *sHandOverDisplayState;
static SPTPlayerTrack *asDJTrack(SPTPlayerTrack *t) { return t; }
static double kSegmentWait = .5;

#define SGLog(...) ((void)0)
static NSString *sSignature;
static SPTPlayerState *SGPlayerState(void) { return testState; }
static NSString *trackKey(SPTPlayerTrack *t) { return t.UID; }
@interface TestPlayer : NSObject <SPTPlayer> @end
@implementation TestPlayer
- (id)pause:(id)options {
    [commands addObject:@"pause requested"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        testState.isPaused = YES; [commands addObject:@"pause acknowledged"];
    }); return @YES;
}
- (id)resume:(id)options {
    assert(testState.track == landingTarget);
    testState.isPaused = NO; [commands addObject:@"resume"];
    return @YES;
}
@end
static id queuePlayer(void) { static TestPlayer *p; if (!p) p = [TestPlayer new]; return p; }
static BOOL canMuteDJLocally(void) { return YES; }
static BOOL queueInCore(id t) { queueCalls++; return YES; }
static void hideTrack(id t, id reason) {}
static void refreshReaders(void) {}
static void noteCopy(id a, id b) {}
static id skipForward(SPTPlayerTrack *t) {
    // A muted bridge may skip directly without changing the transport to Paused.
    assert(atomic_load(&sg_djTransitionMuted));
    if (!t) { [commands addObject:@"advance into voice"]; t = nextPhysicalSong ?: landingTarget; nextPhysicalSong = nil; }
    else [commands addObject:t == landingTarget ? @"skip destination" : @"skip anchor"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, skipAcknowledgementDelay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        testState.track = t;
        testState.future = prefetchedNext ? (t == landingTarget ? @[prefetchedNext] : @[landingTarget,prefetchedNext]) : @[landingTarget];
        testState.isPaused = NO;
    }); return @YES;
}
''' + function('shownDJTrack') + function('shownDJStateBase') + function('lastOfSegment') + function('finishDJLanding') + function('landAtSegmentEnd') + function('skipRepeatedCurrentIntoOutro')
    tests = tests.replace('    puts("DJ history and spent-track decisions: PASS");', r'''
    float left[8], right[8]; for (int i=0;i<8;i++) left[i]=right[i]=.25;
    AudioBufferList buffers = {2, {{1,sizeof left,left},{1,sizeof right,right}}};
    AudioUnitRenderActionFlags flags = 0;
    SGPlayerSetDJTransitionMuted(YES); muteDJTransition(&flags,&buffers);
    assert(flags & kAudioUnitRenderAction_OutputIsSilence);
    for (int i=0;i<8;i++) assert(left[i]==0 && right[i]==0);
    SGPlayerSetDJTransitionMuted(NO); left[0]=.25; flags=0;
    muteDJTransition(&flags,&buffers); assert(left[0]==.25 && flags==0);
    // An interrupted main thread cannot leave the render output silent.
    SGPlayerSetDJTransitionMuted(YES);
    atomic_store(&sg_djMuteDeadline, mach_continuous_time() - 1);
    left[0]=.25; flags=0; muteDJTransition(&flags,&buffers);
    assert(!SGPlayerDJTransitionMuted() && left[0]==.25 && flags==0);
    testState = state; state.track = five; state.contextURI = @"DJ";
    state.future = @[three]; state.isPaused = NO;
    landingTarget = song(@"new-segment"); commands = [NSMutableArray array];
    sHandingOver = NO; landAtSegmentEnd(nil);
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:3];
    while (sHandingOver && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(!sHandingOver && !atomic_load(&sg_djTransitionMuted) && !state.isPaused && state.track == landingTarget);
    NSArray *expected = @[@"skip anchor", @"skip destination"];
    assert([commands isEqual:expected]);
    assert(![commands containsObject:@"pause requested"]);
    // Reuse an existing queued copy, generate the next segment before starting it.
    sPlayed = [@[four,five,one,two] mutableCopy];
    state.track = two; state.future = @[copy,three,four,five,outro]; state.isPaused = NO;
    landingTarget = copy; prefetchedNext = fresh; sAheadQueued = three; commands = [NSMutableArray array]; queueCalls = 0;
    landAtSegmentEnd(three);
    limit = [NSDate dateWithTimeIntervalSinceNow:3];
    while (sHandingOver && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(!sHandingOver && state.track == copy && state.future.firstObject == fresh && queueCalls == 0);
    assert(![commands containsObject:@"pause requested"]);
    prefetchedNext = nil; sAheadQueued = nil; sPlayed = [@[one,two,three,four,five] mutableCopy];
    // UID confirmation alone would open the gate on the song before the shared-UID voice.
    sHandingOver = YES; sHandOverAnchorUID = five.UID; sHandOverDisplayTrack = four;
    assert(shownDJTrack(five) == four); assert(shownDJTrack(outro) == four);
    sHandOverDisplayState = [SPTPlayerState new]; sHandOverDisplayState.track = four; sHandOverDisplayState.position = 99;
    state.track = five; state.position = 0;
    assert(shownDJStateBase(state).position == 99);
    state.track = four; state.isPaused = YES;
    assert(shownDJStateBase(state) == sHandOverDisplayState && !shownDJStateBase(state).isPaused);
    state.track = outro; assert(shownDJStateBase(state) == sHandOverDisplayState);
    landingTarget = outro; commands = [NSMutableArray array];
    state.track = copyFive; state.position = 100; nextPhysicalSong = copyFive; sHandingOver = YES; SGPlayerSetDJTransitionMuted(YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .02 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        state.track = five; state.position = 0;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .07 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        assert(atomic_load(&sg_djTransitionMuted)); assert(state.track != landingTarget);
    });
    finishDJLanding(queuePlayer(), outro, copyFive.UID, YES, YES);
    limit = [NSDate dateWithTimeIntervalSinceNow:3];
    while (sHandingOver && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(state.track == outro && !sHandingOver && !atomic_load(&sg_djTransitionMuted));
    assert(([commands isEqualToArray:@[@"advance into voice",@"advance into voice"]]));
    // A reordered final song from Spotify's queue must not flicker Pause/Play.
    // The output gate still covers every intermediate item until the voice lands.
    state.track = copyFive; state.position = 0; state.isPaused = NO; state.future = @[five,outro,fresh];
    landingTarget = outro; commands = [NSMutableArray array]; sHandingOver = NO;
    // The test begins on a copy at position zero. Its first poll must not
    // confuse the still-pending targeted skip with a completed same-UID hop.
    // Deliberately deliver the fake core's acknowledgement after four polls.
    skipAcknowledgementDelay = .23;
    skipRepeatedCurrentIntoOutro(outro);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, .04 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        assert(atomic_load(&sg_djTransitionMuted));
        assert(![commands containsObject:@"pause requested"]);
    });
    limit = [NSDate dateWithTimeIntervalSinceNow:3];
    while (sHandingOver && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(!sHandingOver && !atomic_load(&sg_djTransitionMuted) && state.track == outro);
    if (![commands isEqualToArray:@[@"skip destination"]])
        NSLog(@"Unexpected commands before outro acknowledgement: %@", commands);
    assert([commands isEqualToArray:@[@"skip destination"]]);
    skipAcknowledgementDelay = .08;
    puts("DJ history, duplicate outro and uninterrupted transport bridge: PASS");''')
    path.write_text(prelude + '\n'.join(function(n) for n in names) + handover + tests)
    subprocess.run(['xcrun','clang','-fobjc-arc','-Werror','-Wno-unused-function','-framework','Foundation',str(path),'-o',str(Path(tmp)/'check')],check=True)
    subprocess.run([str(Path(tmp)/'check')],check=True)
