// Colored segment overlay for Spotify's Now Playing progress bar.
// Ported from EeveeSpotify Reincarnated (GPL-3.0).

#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockSkipper.h"
#import "Core/SGCore.h"

@interface SGSponsorBlockSegmentBar : UIView
@property (nonatomic) CGFloat startRatio;
@property (nonatomic) CGFloat endRatio;
@end

@implementation SGSponsorBlockSegmentBar
@end

@interface SGSponsorBlockOverlayContainer : UIView
@property (nonatomic, copy) NSString *cachedEpisodeID;
@property (nonatomic) double cachedDuration;
@property (nonatomic) NSArray<SGSponsorBlockSegment *> *cachedRawSegments;
@property (nonatomic) BOOL needsRebuild;
@property (nonatomic) BOOL didScanSubviews;
@property (nonatomic, weak) UIView *cachedTrackView;
@property (nonatomic, weak) UIView *cachedVisualElement;

- (void)rebuildWithSegments:(NSArray<SGSponsorBlockSegment *> *)segments
                   duration:(double)duration
                  episodeID:(NSString *)episodeID
                 trackFrame:(CGRect)trackFrame;
- (void)layoutSegmentsForTrackFrame:(CGRect)trackFrame;
@end

@implementation SGSponsorBlockOverlayContainer

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

- (void)rebuildWithSegments:(NSArray<SGSponsorBlockSegment *> *)segments
                   duration:(double)duration
                  episodeID:(NSString *)episodeID
                 trackFrame:(CGRect)trackFrame {
    _cachedEpisodeID = [episodeID copy];
    _cachedDuration = duration;
    _needsRebuild = NO;

    for (UIView *subview in [self.subviews copy]) {
        [subview removeFromSuperview];
    }

    self.frame = trackFrame;
    CGFloat trackWidth = trackFrame.size.width;
    CGFloat trackHeight = trackFrame.size.height;
    CGFloat corner = MIN(1.0, trackHeight / 2.0);

    for (SGSponsorBlockSegment *seg in segments) {
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

        SGSponsorBlockSegmentBar *bar = [[SGSponsorBlockSegmentBar alloc] initWithFrame:CGRectMake(x, 0, segWidth, trackHeight)];
        bar.startRatio = startRatio;
        bar.endRatio = endRatio;
        UIColor *catColor = SGSponsorBlockCategoryColor(seg.category);
        bar.backgroundColor = [catColor colorWithAlphaComponent:0.65];
        bar.layer.cornerRadius = corner;
        bar.layer.masksToBounds = YES;
        bar.userInteractionEnabled = NO;
        [self addSubview:bar];
    }
}

- (void)layoutSegmentsForTrackFrame:(CGRect)trackFrame {
    self.frame = trackFrame;
    CGFloat trackWidth = trackFrame.size.width;
    CGFloat trackHeight = trackFrame.size.height;
    if (trackWidth <= 0 || trackHeight <= 0) return;

    CGFloat corner = MIN(1.0, trackHeight / 2.0);
    for (UIView *sv in self.subviews) {
        if (![sv isKindOfClass:[SGSponsorBlockSegmentBar class]]) continue;
        SGSponsorBlockSegmentBar *bar = (SGSponsorBlockSegmentBar *)sv;
        CGFloat x = bar.startRatio * trackWidth;
        CGFloat segWidth = MAX(2.0, (bar.endRatio - bar.startRatio) * trackWidth);
        if (x + segWidth > trackWidth) {
            segWidth = MAX(1.0, trackWidth - x);
        }
        bar.frame = CGRectMake(x, 0, segWidth, trackHeight);
        bar.layer.cornerRadius = corner;
        bar.layer.masksToBounds = YES;
    }
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
        for (UIView *sv in slider.subviews) {
            if ([sv isKindOfClass:[SGSponsorBlockOverlayContainer class]]) {
                ((SGSponsorBlockOverlayContainer *)sv).needsRebuild = YES;
            }
        }
        [self updateSlider:slider];
    }
}

// ProgressBar6Slider in the recorded tree has two subviews: _UISlideriOSVisualElement and
// SliderBufferingAnimationView (which sits on the 7 pt track with a 3 pt horizontal inset).
static CGRect resolveTrackFrame(UIView *slider, UIView *trackView) {
    if (trackView && trackView.superview == slider && trackView.frame.size.width > 0 && trackView.frame.size.height > 0) {
        return trackView.frame;
    }
    if ([slider isKindOfClass:UISlider.class]) {
        CGRect tr = [(UISlider *)slider trackRectForBounds:slider.bounds];
        if (tr.size.width > 0 && tr.size.height > 0 && tr.size.width < slider.bounds.size.width) {
            return tr;
        }
    }
    const CGFloat kTrackHeight = 7.0;
    const CGFloat kTrackInset = 3.0;
    CGFloat h = MIN(kTrackHeight, slider.bounds.size.height);
    CGFloat w = MAX(0.0, slider.bounds.size.width - kTrackInset * 2.0);
    return CGRectMake(kTrackInset, (slider.bounds.size.height - h) / 2.0, w, h);
}

+ (void)updateSlider:(UIView *)slider {
    SGSponsorBlockOverlayContainer *container = nil;
    for (UIView *sv in slider.subviews) {
        if ([sv isKindOfClass:[SGSponsorBlockOverlayContainer class]]) {
            container = (SGSponsorBlockOverlayContainer *)sv;
            break;
        }
    }

    if (!SGFlag(SGKeySponsorBlockEnabled, NO) || !SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockOverlay)) {
        if (container) [container removeFromSuperview];
        return;
    }

    SGSponsorBlockSkipper *skipper = [SGSponsorBlockSkipper sharedSkipper];
    NSString *episodeID = skipper.currentEpisodeID;
    double duration = skipper.episodeDuration;
    NSArray<SGSponsorBlockSegment *> *segments = skipper.currentSegments;
    if (!episodeID.length || !isfinite(duration) || duration <= 0 || !segments.count) {
        if (container) [container removeFromSuperview];
        return;
    }

    UIView *bufferingView = container.cachedTrackView;
    UIView *visualElement = container.cachedVisualElement;
    if (!container || !container.didScanSubviews ||
        (bufferingView && bufferingView.superview != slider) ||
        (visualElement && visualElement.superview != slider)) {
        bufferingView = nil;
        visualElement = nil;
        for (UIView *sv in slider.subviews) {
            if (sv == container) continue;
            if (SGClassNamed(sv.class, @"SliderBufferingAnimationView")) {
                bufferingView = sv;
            } else if (SGClassNamed(sv.class, @"_UISlideriOSVisualElement")) {
                visualElement = sv;
            }
        }
        if (container) {
            container.cachedTrackView = bufferingView;
            container.cachedVisualElement = visualElement;
            container.didScanSubviews = YES;
        }
    }

    CGRect trackFrame = resolveTrackFrame(slider, bufferingView);
    if (trackFrame.size.width <= 0 || trackFrame.size.height <= 0) return;

    BOOL needsRebuild = (!container ||
                         container.needsRebuild ||
                         container.cachedRawSegments != segments ||
                         ![container.cachedEpisodeID isEqualToString:episodeID] ||
                         fabs(container.cachedDuration - duration) > 0.001);

    if (!needsRebuild) {
        if (!CGRectEqualToRect(container.frame, trackFrame)) {
            [container layoutSegmentsForTrackFrame:trackFrame];
        }
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
    if (!visible.count) {
        if (container) [container removeFromSuperview];
        return;
    }

    if (!container) {
        container = [[SGSponsorBlockOverlayContainer alloc] initWithFrame:trackFrame];
        container.userInteractionEnabled = NO;
        container.backgroundColor = [UIColor clearColor];
        container.cachedTrackView = bufferingView;
        container.cachedVisualElement = visualElement;
        container.didScanSubviews = YES;

        slider.clipsToBounds = NO;
        if (bufferingView) {
            [slider insertSubview:container aboveSubview:bufferingView];
        } else if (visualElement) {
            [slider insertSubview:container aboveSubview:visualElement];
        } else {
            [slider addSubview:container];
        }
    }

    container.cachedRawSegments = segments;
    [container rebuildWithSegments:visible duration:duration episodeID:episodeID trackFrame:trackFrame];
}

@end
