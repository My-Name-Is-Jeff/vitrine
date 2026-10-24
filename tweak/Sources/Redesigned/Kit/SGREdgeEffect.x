// The redesign's copy of Native/Appearance/EdgeEffect.x.
// Soft top edge: iOS 27 resolves a scroll view's automatic top edge effect to the hard style, the
// flat dark band under the navigation bar (UIKit.ScrollEdgeEffectView in trees/continuous/1.txt).
// Setting the soft style brings back iOS 26's thin fading blur. Set on every layout pass as well as
// on arrival, in case UIKit resolves the style again after the page appears.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "SGRRestyle.h"

// The style last set here, so a layout pass the setter itself causes does not set it again; a hard style here
// stays (SGRHardTopEdge).
static char setKey;

static void soften(UIScrollView *scrollView) {
    if (@available(iOS 26.0, *)) {
        UIScrollEdgeEffect *top = scrollView.topEdgeEffect;
        UIScrollEdgeEffectStyle *hard = UIScrollEdgeEffectStyle.hardStyle;
        if (objc_getAssociatedObject(scrollView, &setKey) == hard) {
            if (top.style != hard) top.style = hard;
            return;
        }
        if (top.style == objc_getAssociatedObject(scrollView, &setKey)) return;
        UIScrollEdgeEffectStyle *soft = UIScrollEdgeEffectStyle.softStyle;
        top.style = soft;
        objc_setAssociatedObject(scrollView, &setKey, top.style, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"soft top edge: first scroll view %@", NSStringFromClass(scrollView.class)); });
    }
}

void SGRHardTopEdge(UIScrollView *scrollView) {
    if (@available(iOS 26.0, *)) {
        UIScrollEdgeEffectStyle *hard = UIScrollEdgeEffectStyle.hardStyle;
        if (objc_getAssociatedObject(scrollView, &setKey) == hard) return;
        scrollView.topEdgeEffect.style = hard;
        objc_setAssociatedObject(scrollView, &setKey, hard, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%hook UIScrollView
- (void)didMoveToWindow {
    %orig;
    if (self.window) soften(self);
}

- (void)layoutSubviews {
    %orig;
    if (self.window) soften(self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
}
