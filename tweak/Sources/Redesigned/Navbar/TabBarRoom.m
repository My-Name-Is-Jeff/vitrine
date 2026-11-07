// What the redesign's tab bar does to Spotify's own bar apart from drawing itself (TabBar.x): the hold on Home that
// opens Mod Settings, and the room made under Spotify's bar for the taller bar of the mod's.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "Settings/SGPage.h"

#pragma mark - the hold on Home

@interface SGRHomeHold : UILongPressGestureRecognizer
@end

@implementation SGRHomeHold
+ (void)held:(SGRHomeHold *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) SGOpenModSettings(hold.view);
}
@end

// On Spotify's own bar a hold that begins fails the item's tap recognizer, so Home is not tapped too.
void SGRHoldHomeForModSettings(UIView *stockBar) {
    UIView *home = SGRowIn(stockBar).arrangedSubviews.firstObject;
    if (!home) return;
    for (UIGestureRecognizer *recognizer in home.gestureRecognizers) {
        if ([recognizer isKindOfClass:SGRHomeHold.class]) return;
    }
    [home addGestureRecognizer:[[SGRHomeHold alloc] initWithTarget:SGRHomeHold.class action:@selector(held:)]];
}

#pragma mark - room for the glass bar

// UIKit's glass bar asks for 83 pt, the platter the top 62 of it, over no more safe area than a Face ID
// phone's 34 (simulator, iOS 26.5 and 27). Spotify's bar is its 49 pt row over the bottom safe area of
// TabBarContainerImpl's view: a guide from 49 pt above the safe area's bottom to the view's bottom sets
// its height (its viewDidLoad, 0x100840a2c), the now playing bar stands on that guide's top
// (MainUIContainer's chrome bottom anchor, 0x100ae0178), the bar slides away by the inset plus 49 when
// Spotify hides it (0x1037169a4) and the pages get 49 on top of the inset (0x10707bde4). A Face ID
// phone gives the view 34 and the two bars match. A phone with a home button gives it none, and so does
// Spotify's message bar (LimitedExperienceIndicatorBar: Offline, Private Session) coming in under the
// tab bar, which takes the home indicator's inset for itself, so the glass bar would stand over the now
// playing bar. So the view gets the rest of the glass bar's height as safe area, and Spotify lays its bar,
// the now playing bar, the pages and the hide out for the glass bar itself, and moves them all with the
// message bar.
static const CGFloat kStockRow = 49;
static CGFloat sg_room, sg_glassHeight, sg_roomInset = -1;

CGFloat SGRTabBarRoom(void) {
    return sg_room;
}

// UIKit asks for 62 + max(21, inset) on a phone with a home button, max(83, 49 + inset) on a Face ID
// phone, by the safe area of the view the bar stands in. The bar's host keeps the room out of that; if
// it ever reached the bar again, the bar would ask for more room every pass, so what it asks for with
// no room made is what is kept. It is asked of the full bar on screen only: the minimized bar holds other items
// (one glyph, no title) and asks for another height, and a room that changed as the bar minimized moved the page's
// inset from inside -[UIScrollView setContentOffset:], the scroll answered it, and the app hung (c52af73).
CGFloat SGRTabBarGlassHeight(UITabBar *bar, UIView *stockBar) {
    BOOL canAsk = bar.window && !SGRTabBarMinimized();
    if (sg_glassHeight <= 0 || (canAsk && sg_room < 0.5)) {
        CGFloat height = [bar sizeThatFits:CGSizeMake(stockBar.bounds.size.width, kStockRow)].height;
        if (height > 0) sg_glassHeight = height;
    }
    return sg_glassHeight;
}

void SGRMakeTabBarRoom(UIViewController *container, UIView *stockBar, UITabBar *bar) {
    if (!bar.window || !container.isViewLoaded || ![stockBar isDescendantOfView:container.view]) return;
    UIEdgeInsets extra = container.additionalSafeAreaInsets;
    CGFloat inset = container.view.safeAreaInsets.bottom - extra.bottom;
    // Minimizing never moves the room: only the safe area from outside (the message bar) does, minimized or not.
    if (SGRTabBarMinimized() && fabs(inset - sg_roomInset) < 0.5) return;
    sg_roomInset = inset;
    CGFloat height = SGRTabBarGlassHeight(bar, stockBar);
    // Spotify's regular width bar is a fixed 76 pt that ignores the inset.
    BOOL compact = container.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    CGFloat room = compact ? MAX(0, ceil(height - kStockRow - inset)) : 0;
    if (fabs(extra.bottom - room) < 0.5) return;
    sg_room = extra.bottom = room;
    container.additionalSafeAreaInsets = extra;
    SGLog(@"tab bar: %.0f pt of room made under Spotify's bar for the glass bar's %.0f, over an inset of %.0f", room, height, inset);
}
