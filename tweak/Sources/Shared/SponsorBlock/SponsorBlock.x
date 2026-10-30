// SponsorBlock entry point and progress bar overlay hook.
// Ported from EeveeSpotify Reincarnated (GPL-3.0).

#import "SGSponsorBlock.h"
#import "SGSponsorBlockOverlay.h"
#import "Core/SGCore.h"

%hook _TtCO17NowPlaying_ECMKit11ProgressBar6Slider

- (void)layoutSubviews {
    %orig;
    [SGSponsorBlockOverlay attachToSlider:(UIView *)self];
}

%end

%ctor {
    SGSponsorBlockStart();
    %init;
    SGRequireClasses(@[@"_TtCO17NowPlaying_ECMKit11ProgressBar6Slider"]);
}
