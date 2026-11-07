// What minimizes the glass bar and what brings it back (TabBar.x draws it): a page scrolled down by a
// finger or the fling after it, and scrolled back up or to its top (MinimizeStep.h). After the bar changes some
// other way (a tap on its circle, a tab, the player), only a new touch minimizes it again: the fling still
// running would otherwise undo the tap at once; another tab (TabBar.x);
// and the full screen player opening or closing, which takes Spotify's pictures of the bars to move with it
// and would have moved the card from the tab bar's row back up to its place above the bar.
//
// Only a page's own scroll views count: those inside Spotify's tab bar container. The player and the now
// playing bar are outside it, and a shelf scrolling sideways has nothing to scroll down.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "MinimizeStep.h"
#import "Shared/Player/PlayerEvents.h"

static Class sg_containerClass;
static __weak UIScrollView *sg_page, *sg_other;
static SGRMinimizeTrack sg_track;
static BOOL sg_waitForTouch;

static BOOL inContainer(UIView *view) {
    for (UIResponder *r = view.nextResponder; r; r = r.nextResponder) if ([r isKindOfClass:sg_containerClass]) return YES;
    return NO;
}

static void scrolled(UIScrollView *scrollView) {
    if ((!scrollView.isTracking && !scrollView.isDecelerating) || scrollView == sg_other) return;
    CGFloat offset = scrollView.contentOffset.y;
    BOOL currentMinimized = SGRTabBarMinimizedTarget();
    if (scrollView != sg_page) {
        if (!inContainer(scrollView)) {
            sg_other = scrollView;
            return;
        }
        sg_page = scrollView;
        sg_track = (SGRMinimizeTrack){offset, currentMinimized};
    }
    // The bar changed some other way (a tab, the player): the scroll counts from here.
    if (sg_track.minimized != currentMinimized) {
        sg_track = (SGRMinimizeTrack){offset, currentMinimized};
        sg_waitForTouch = YES;
    }
    if (scrollView.isTracking) sg_waitForTouch = NO;
    UIEdgeInsets inset = scrollView.adjustedContentInset;
    CGFloat top = -inset.top, bottom = scrollView.contentSize.height + inset.bottom - scrollView.bounds.size.height;
    BOOL allowMinimize = SGEnabled(SGRKeyNavbarMinimize) && !sg_waitForTouch;
    CGFloat progress = allowMinimize ? SGRMinimizeProgress(&sg_track, offset, top, bottom) : 0;
    BOOL minimized = SGRMinimizeStep(&sg_track, offset, top, bottom);
    if (minimized == currentMinimized || (minimized && !allowMinimize)) {
        if (minimized && !allowMinimize) sg_track.minimized = currentMinimized;
        SGRSetTabBarScrollSquish(minimized ? 0 : progress, NO);
        return;
    }
    SGRSetTabBarScrollSquish(0, NO);
    SGRSetTabBarMinimized(minimized, YES);
}

%hook UIScrollView
- (void)setContentOffset:(CGPoint)offset {
    %orig;
    scrolled(self);
}
%end

%hook UIPanGestureRecognizer
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (self.view == sg_page) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!sg_page.isTracking && !sg_page.isDecelerating && !SGRTabBarMinimizedTarget()) {
                sg_track.turn = sg_page.contentOffset.y;
                SGRSetTabBarScrollSquish(0, YES);
            }
        });
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    %orig;
    if (self.view == sg_page) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!sg_page.isTracking && !sg_page.isDecelerating && !SGRTabBarMinimizedTarget()) {
                sg_track.turn = sg_page.contentOffset.y;
                SGRSetTabBarScrollSquish(0, YES);
            }
        });
    }
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    sg_containerClass = NSClassFromString(@"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl");
    if (!sg_containerClass) return;
    %init;
    [NSNotificationCenter.defaultCenter addObserverForName:SGPlayerTransitionNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) { SGRSetTabBarMinimized(NO, NO); }];
}
