// Redesign: Who's listening: the Add account circle on glass, and no blur behind its bar.
//
//   Who's listening   AccountSwitching_AccountPickerImpl.AccountPickerAddAccountTableViewCell:
//                     the 64pt circle at the head of the row, a plain UIView filled white at 7%, with the plus drawn
//                     over it by a sibling SPTEncoreIconView. The fill goes and a glass circle takes its place inside
//                     it; the plus stays above, since it comes after the circle in the cell's content view.
//
// Nothing clips the circle: it is a plain view with a corner radius and no mask, in a content view that does not clip
// either (the table's own clip is the screen's). The accounts' avatars are not touched: they are photographs and
// initials on colour, not controls drawn as a fill.
//
// Below iOS 26 the circle is AccountPlus.x's (glass with the white film, held clear as the row is selected); this one is
// iOS 26's, so the two never both put glass in it.
//
// The page has no title in its bar, yet Spotify's blur stands over the top 91pt of it (the plain view of the
// navigation controller's that holds a UIVisualEffectView, #1C1C1C at 73%), a grey band over the heading. The page is
// registered with the bar pages (Pages.h), which keep that blur off while it is on top.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static char kAddGlassKey;

static void dressAdd(UITableViewCell *cell) {
    for (UIView *view in cell.contentView.subviews) {
        if (![view isMemberOfClass:UIView.class]) continue;
        CGSize size = view.bounds.size;
        if (fabs(size.width - size.height) > 0.5 || size.width < 40 || size.width > 80) continue;
        if (!SGIsFaintWhite(view.layer.backgroundColor) && !objc_getAssociatedObject(view, &kAddGlassKey)) continue;
        if (view.backgroundColor && ![view.backgroundColor isEqual:UIColor.clearColor]) view.backgroundColor = UIColor.clearColor;
        if (view.layer.backgroundColor) view.layer.backgroundColor = NULL;
        SGRGlassInside(view, &kAddGlassKey, size.width);
    }
}

%group SGRAccountPickerGlass
%hook SGRAddAccountCell
- (void)layoutSubviews {
    %orig;
    dressAdd((UITableViewCell *)self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    Class cell = SGRSwiftClass(@"AccountSwitching_AccountPickerImpl", @"AccountPickerAddAccountTableViewCell");
    if (!SGBelowiOS26()) {
        if (cell) %init(SGRAccountPickerGlass, SGRAddAccountCell = cell);
        else SGLog(@"class AccountSwitching_AccountPickerImpl.AccountPickerAddAccountTableViewCell not found, Who's listening keeps Spotify's Add account circle");
    }
    Class page = SGRSwiftClass(@"AccountSwitching_AccountPickerImpl", @"AccountPickerViewController");
    if (page) {
        SGRRegisterBarPages(^BOOL(UIViewController *top) { return SGRPageIsOrHolds(top, page); });
    } else {
        SGLog(@"class AccountSwitching_AccountPickerImpl.AccountPickerViewController not found, Who's listening keeps Spotify's blur behind its bar");
    }
}
