// The DJ under Spoof Premium. A yes from this checker sends the DJ to its full session, which the server refuses a
// Free account with "DJ is not available in your country" (DJMRegionUnavailableDialogEffectHandler). A no keeps it on
// the DJ playlist, which plays. A US Free account already gets a no; this makes it the answer everywhere.
#import "Core/SGCore.h"
#import "AdBlock.h"

%hook _TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl
- (void)isEligibleForDJWithCompletion:(void (^)(BOOL))completion {
    if (completion) completion(NO);
}
%end

%ctor {
    if (!SGHidden(SGKeyFakePremium)) return;
    %init;
    SGRequireClasses(@[@"_TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl"]);
}
