// Core SponsorBlock skipper conforming to SGPlayerStateObserver.
// Ported from EeveeSpotify Reincarnated (GPL-3.0).
#import <Foundation/Foundation.h>
#import "Shared/Player/PlayerState.h"
#import "SGSponsorBlock.h"

@interface SGSponsorBlockSkipper : NSObject <SGPlayerStateObserver>

+ (instancetype)sharedSkipper;
- (void)start;

@end
