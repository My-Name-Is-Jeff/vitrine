// Colored segment overlay for Spotify's Now Playing progress bar.
// Ported from EeveeSpotify Reincarnated (GPL-3.0).

#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockSkipper.h"
#import "Core/SGCore.h"

@interface SGSponsorBlockOverlayContainer : UIView
@end

@implementation SGSponsorBlockOverlayContainer
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}
@end

static NSHashTable<UIView *> *s_trackedSliders = nil;

@implementation SGSponsorBlockOverlay

+ (void)initialize {
    if (self == [SGSponsorBlockOverlay class]) {
        s_trackedSliders = [NSHashTable weakObjectsHashTable];
    }
}

+ (void)attachToSlider:(UIView *)slider {
    if (!slider) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attachToSlider:slider];
        });
        return;
    }
    [s_trackedSliders addObject:slider];
    [self updateSlider:slider];
}

+ (void)refreshAll {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAll];
        });
        return;
    }
    for (UIView *slider in s_trackedSliders.allObjects) {
        [self updateSlider:slider];
    }
}

+ (void)updateSlider:(UIView *)slider {
    for (UIView *subview in [slider.subviews copy]) {
        if ([subview.accessibilityIdentifier isEqualToString:@"SGSponsorBlockOverlay"]) {
            [subview removeFromSuperview];
        }
    }

    if (!SGFlag(SGKeySponsorBlockEnabled, NO) || !SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockOverlay)) {
        return;
    }

    SGSponsorBlockSkipper *skipper = [SGSponsorBlockSkipper sharedSkipper];
    NSString *episodeID = skipper.currentEpisodeID;
    double duration = skipper.episodeDuration;
    NSArray<SGSponsorBlockSegment *> *segments = skipper.currentSegments;
    if (!episodeID.length || !isfinite(duration) || duration <= 0 || !segments.count) {
        return;
    }

    NSTimeInterval minDuration = SGSponsorBlockMinDuration();
    NSMutableArray<SGSponsorBlockSegment *> *visible = [NSMutableArray array];
    for (SGSponsorBlockSegment *seg in segments) {
        if (![seg.actionType isEqualToString:@"skip"]) continue;
        if (seg.duration < minDuration) continue;
        if (SGSponsorBlockCategoryBehavior(seg.category) == SGSponsorBlockBehaviorOff) continue;
        [visible addObject:seg];
    }
    if (!visible.count) return;

    CGRect trackFrame = CGRectZero;
    for (UIView *sv in slider.subviews) {
        NSString *clsName = NSStringFromClass([sv class]);
        if ([clsName containsString:@"AudioView"] || [clsName containsString:@"ProgressTrack"]) {
            if (sv.frame.size.width > 0 && sv.frame.size.height > 0) {
                trackFrame = sv.frame;
                break;
            }
        }
    }
    if (CGRectIsEmpty(trackFrame) || trackFrame.size.width <= 0) {
        CGFloat h = MAX(2.0, MIN(4.0, slider.bounds.size.height));
        trackFrame = CGRectMake(0, (slider.bounds.size.height - h) / 2.0, slider.bounds.size.width, h);
    }
    if (trackFrame.size.width <= 0 || trackFrame.size.height <= 0) return;

    SGSponsorBlockOverlayContainer *container = [[SGSponsorBlockOverlayContainer alloc] initWithFrame:trackFrame];
    container.accessibilityIdentifier = @"SGSponsorBlockOverlay";
    container.userInteractionEnabled = NO;
    container.backgroundColor = [UIColor clearColor];
    container.layer.zPosition = 0.5;

    CGFloat trackWidth = trackFrame.size.width;
    CGFloat trackHeight = trackFrame.size.height;

    for (SGSponsorBlockSegment *seg in visible) {
        CGFloat startRatio = (CGFloat)(seg.start / duration);
        CGFloat endRatio = (CGFloat)(seg.end / duration);
        if (startRatio < 0.0) startRatio = 0.0;
        if (endRatio > 1.0) endRatio = 1.0;
        if (endRatio <= startRatio) continue;

        CGFloat x = startRatio * trackWidth;
        CGFloat segWidth = MAX(2.0, (endRatio - startRatio) * trackWidth);
        if (x + segWidth > trackWidth) {
            segWidth = MAX(1.0, trackWidth - x);
        }

        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(x, 0, segWidth, trackHeight)];
        UIColor *catColor = SGSponsorBlockCategoryColor(seg.category);
        bar.backgroundColor = [catColor colorWithAlphaComponent:0.65];
        bar.layer.cornerRadius = MIN(1.0, trackHeight / 2.0);
        bar.layer.masksToBounds = YES;
        bar.userInteractionEnabled = NO;
        [container addSubview:bar];
    }

    if (container.subviews.count > 0) {
        slider.clipsToBounds = NO;
        UIView *thumbView = nil;
        for (UIView *sv in slider.subviews) {
            NSString *clsName = NSStringFromClass([sv class]);
            if ([clsName containsString:@"Thumb"] || [clsName containsString:@"Knob"]) {
                thumbView = sv;
                break;
            }
        }
        if (thumbView) {
            [slider insertSubview:container belowSubview:thumbView];
        } else {
            [slider addSubview:container];
        }
    }
}

@end
