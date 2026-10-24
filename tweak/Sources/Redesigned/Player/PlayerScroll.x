// Player redesign: the player never scrolls up, and has no top edge blur. Scrolling stays on because Spotify's dismiss pull rides on
// the list's own pan and starts only at its top, so the offset is clamped instead; the insets stay
// Spotify's, since changing one mid-drag moves the offset under the finger.
//
// That pull is no scrub's, though: a finger dragging the progress bar that drifts down closed the player
// instead of seeking (issue #172). A scroll view lets a UIControl in it track a touch while its own pan
// runs on the same touch, so the list's pan is turned off from the moment the slider tracks a touch until
// it lets go. The volume row's slider holds it the same way.
//
// Spotify's tap-to-scroll band, a plain view over the bottom 55pt drawn after the list, scrolls the list
// down a step on a tap. With the list held at the top that step is taken straight back, and the band
// covers the lower half of the footer's glyphs, which the redesign lowers into it (PlayerFooter.x). So the
// band takes no touches at all; they fall to the list, where the footer's reach and the dismiss pull are.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static NSString *const kListIdentifier = @"scrolling_npv_collection_view_accessibility_identifier";

static __weak UIScrollView *sg_loggedList;

// Nothing scrolls under the header, which is in the list itself: the top edge's blur only blurs it. Set from the
// list's own layout, since the first scroll waits for a finger.
static void hideTopEdge(UIScrollView *list) {
    if (@available(iOS 26.0, *)) {
        if (!list.topEdgeEffect.hidden && [list.accessibilityIdentifier isEqualToString:kListIdentifier]) list.topEdgeEffect.hidden = YES;
    }
}

static void holdAtTop(UIScrollView *list) {
    if (![list.accessibilityIdentifier isEqualToString:kListIdentifier]) return;
    CGFloat top = -list.adjustedContentInset.top;
    CGPoint offset = list.contentOffset;
    if (offset.y <= top) return;
    CGFloat past = offset.y - top;
    list.contentOffset = CGPointMake(offset.x, top);

    if (sg_loggedList == list) return;
    sg_loggedList = list;
    SGLog(@"redesign player: scroll held at the top, %.0fpt up taken back (%@)", past, list.isDragging ? @"drag" : @"no finger");
}

%hook UICollectionView
- (void)didMoveToWindow {
    %orig;
    if (self.window) hideTopEdge(self);
}

- (void)layoutSubviews {
    %orig;
    hideTopEdge(self);
}
%end

%hook _TtC21NowPlaying_ScrollImpl23NPVScrollViewController
- (void)scrollViewDidScroll:(UIScrollView *)list {
    holdAtTop(list);
    %orig;
}
%end

%hook _TtC21NowPlaying_ScrollImpl28NPVTapToScrollViewController
- (void)viewDidLoad {
    %orig;
    ((UIViewController *)self).view.userInteractionEnabled = NO;
}
%end

#pragma mark - a scrub is not a pull

// The list whose pan a scrub turned off, so only that one is turned back on: a pan off for some other
// reason stays off. One finger scrubs at a time, so one is enough. The slider that holds it is kept too:
// MPVolumeView swaps its slider on a route change, and the old one leaving its window ends no other scrub.
static __weak UIScrollView *sg_scrubbedList;
static __weak UIView *sg_scrubber;

static void scrubBegan(UIView *slider) {
    UIScrollView *list = nil;
    for (UIView *v = slider.superview; v && !list; v = v.superview) {
        if ([v isKindOfClass:UIScrollView.class] && [v.accessibilityIdentifier isEqualToString:kListIdentifier]) list = (UIScrollView *)v;
    }
    // Once per slider class and answer: the volume slider is hooked app-wide, and the progress bar's answer still shows.
    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    NSString *what = [NSString stringWithFormat:@"a scrub on %@ %@", NSStringFromClass(slider.class),
                      list ? @"holds the list's pan" : @"found no list above the slider"];
    if (![logged containsObject:what]) {
        [logged addObject:what];
        SGLog(@"redesign player: %@", what);
    }
    if (!list.panGestureRecognizer.enabled) return;
    list.panGestureRecognizer.enabled = NO;
    sg_scrubbedList = list;
    sg_scrubber = slider;
}

static void scrubEnded(UIView *slider) {
    if (slider != sg_scrubber) return;
    sg_scrubbedList.panGestureRecognizer.enabled = YES;
    sg_scrubbedList = nil;
    sg_scrubber = nil;
}

// Shared/Haptics/ControlHaptics.x hooks the same begin for the scrub's taps; both call through.
%hook _TtCO17NowPlaying_ECMKit11ProgressBar6Slider
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL tracking = %orig;
    if (tracking) scrubBegan((UIView *)self);
    return tracking;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    scrubEnded((UIView *)self);
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    scrubEnded((UIView *)self);
}

// A lock, a call or the player going some other way can take the slider off screen mid-scrub, and then
// neither of the two above may come.
- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) scrubEnded((UIView *)self);
}
%end

// The volume row's slider (PlayerVolume.m) is held the same way: a drag along it that drifts down is the volume's.
%hook MPVolumeSlider
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    BOOL tracking = %orig;
    if (tracking) scrubBegan((UIView *)self);
    return tracking;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    %orig;
    scrubEnded((UIView *)self);
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    %orig;
    scrubEnded((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) scrubEnded((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC21NowPlaying_ScrollImpl23NPVScrollViewController",
        @"_TtC21NowPlaying_ScrollImpl28NPVTapToScrollViewController",
        @"_TtCO17NowPlaying_ECMKit11ProgressBar6Slider",
        @"MPVolumeSlider",
    ]);
}
