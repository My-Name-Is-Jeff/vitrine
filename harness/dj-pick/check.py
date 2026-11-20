#!/usr/bin/env python3
"""Check the direct neutral DJ request without any native Pick interception."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'tweak/Sources/Shared/Player/DJPick.x').read_text()
queue_path = root / 'tweak/Sources/Shared/Player/DJQueue.x'
import re
queue = re.sub(r'^#include "(DJQueue[^"]+\.inc)"$',
               lambda m: (queue_path.parent / m.group(1)).read_text(),
               queue_path.read_text(), flags=re.M)
settings = (root / 'tweak/Sources/Shared/Player/PlayerSettings.m').read_text()
header = (root / 'tweak/Sources/Shared/Player/DJPick.h').read_text()
assert '%hook' not in source and '%ctor' not in source, 'native DJ hook was retained'
assert 'jumpWithCompletion:' not in source and 'jumpWithCompletion:' not in queue
assert 'SGKeyDJPickFallback' not in source + header + settings
assert 'Neutral request fallback' not in settings
assert 'SGDJPickRequest(queuePlayer()' in queue
assert 'SGDJPickRequest(id player,' in header
assert 'SGPBString(1, @"Surprise me with a new mix based on my taste.")' in source
assert 'SGPBVarint(2, 3)' in source
assert 'NSSelectorFromString(@"signal:parameters:options:loggingParams:")' in source
assert 'kDJPromptTimeout = 20' in source
print('Direct DJ request, native hook removal and obsolete setting: PASS')

if sys.platform != 'darwin':
    print('Foundation request/landing tests: macOS required (not run)')
    sys.exit(0)

production = source[source.index('static const NSTimeInterval'):]
prelude = r'''
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import "Protobuf.h"
#include <assert.h>
#define SGLog(...) do {} while (0)
@interface SPTPlayerTrack : NSObject
@property NSString *URI, *UID, *provider;
@property NSDictionary *metadata;
@end
@implementation SPTPlayerTrack @end
@interface SPTPlayerState : NSObject
@property NSString *contextURI;
@property SPTPlayerTrack *track;
@property BOOL isPaused;
@property NSArray *supported;
- (NSArray *)signals;
@end
@implementation SPTPlayerState
- (NSArray *)signals { return self.supported; }
@end
@protocol SPTPlayer
- (SPTPlayerState *)state;
@end
static NSString *SGURIString(id uri) { return uri; }
static int began, ended, changedCount;
static void SGDJQueueBeginPick(void) { began++; }
static void SGDJQueueFinishPick(BOOL changed) { ended++; changedCount += changed; }
@interface FakePlayer : NSObject <SPTPlayer>
@property SPTPlayerState *state;
@property NSUInteger requests;
@property NSString *lastSignal, *parameters;
- (id)signal:(id)signal parameters:(id)parameters options:(id)options loggingParams:(id)logging;
@end
@implementation FakePlayer
- (id)signal:(id)signal parameters:(id)parameters options:(id)options loggingParams:(id)logging {
    self.requests++; self.lastSignal = signal; self.parameters = parameters;
    return nil;
}
@end
'''
tests = r'''
static int callbacks, errors;
static FakePlayer *player(void) {
    FakePlayer *p = [FakePlayer new];
    p.state = [SPTPlayerState new];
    p.state.contextURI = @"spotify:playlist:37i9dQZF1EYkqdzj48dyYq";
    p.state.track = [SPTPlayerTrack new];
    p.state.track.URI = @"spotify:track:old";
    p.state.track.UID = @"old";
    p.state.track.metadata = @{ @"page_instance_id": @"old-page" };
    p.state.supported = @[@"prompt", @"jump"];
    return p;
}
static void reset(void) { began = ended = changedCount = callbacks = errors = 0; }
static void request(FakePlayer *p) {
    SGDJPickRequest(p, ^(NSError *e) { callbacks++; errors += e != nil; });
}
static void poll(NSTimeInterval seconds) {
    SGDJPickAttempt *a = sDJPickAttempt;
    assert(a);
    [a pollAt:a.started + seconds];
}
int main(void) { @autoreleasepool {
    reset(); FakePlayer *p = player(); request(p);
    assert(p.requests == 1 && began == 1 && ended == 0);
    assert([p.lastSignal isEqual:@"prompt"]);
    NSData *wire = [[NSData alloc] initWithBase64EncodedString:p.parameters options:0];
    NSArray *fields = SGPBParse(wire);
    assert([SGPBText(SGPBFirst(fields, 1)) isEqual:@"Surprise me with a new mix based on my taste."]);
    assert(SGPBFirst(fields, 2).varint == 3);
    SGDJPickRequest(p, nil);
    assert(p.requests == 1);  // repeated tap does not send a second prompt
    p.state.track.URI = @"spotify:track:still-old-page";
    p.state.track.UID = @"another";
    poll(0.2);
    assert(callbacks == 0); // same page is NOT a successful new set
    p.state.track.URI = @"spotify:media:intro";
    p.state.track.UID = @"list_intro_item";
    p.state.track.metadata = @{ @"page_instance_id": @"new-page" };
    poll(0.3);
    assert(callbacks == 1 && errors == 0 && ended == 1 && changedCount == 1 && !sDJPickAttempt);

    reset(); p = player(); request(p);
    p.state.track.provider = @"queue";
    p.state.track.UID = @"queued-copy";
    p.state.track.URI = @"spotify:track:copy";
    p.state.track.metadata = @{ @"page_instance_id": @"new-page" };
    poll(0.4);
    assert(callbacks == 0 && changedCount == 0); // manual queue not a new DJ set
    poll(20.1);
    assert(callbacks == 1 && errors == 1 && ended == 1 && changedCount == 0);

    reset(); p = player(); request(p);
    p.state.contextURI = @"spotify:album:another";
    poll(0.1);
    assert(callbacks == 1 && errors == 1 && changedCount == 0); // context cancelled

    reset(); p = player(); request(p);
    p.state.isPaused = YES;
    poll(0.1);
    assert(callbacks == 1 && errors == 0 && changedCount == 0); // pause cancelled

    reset(); p = player(); p.state.supported = @[@"jump"]; request(p);
    assert(p.requests == 0 && callbacks == 1 && errors == 1 && began == 0);
    reset(); p = player(); p.state.contextURI = @"spotify:album:no-dj"; request(p);
    assert(p.requests == 0 && callbacks == 1 && errors == 1 && began == 0);
    assert(DJPickContext([SPTPlayerState new]) == nil);
    puts("DJ Pick: one direct prompt, true landing, no native jump, pause, timeout, unsupported context: PASS");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='vitrine-dj-pick-') as d:
    main = Path(d) / 'check.m'
    exe = Path(d) / 'check'
    main.write_text(prelude + production + tests)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', '-framework', 'QuartzCore',
                    '-I', str(root / 'tweak/Sources/Shared/AdBlock'), str(main),
                    str(root / 'tweak/Sources/Shared/AdBlock/Protobuf.m'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
