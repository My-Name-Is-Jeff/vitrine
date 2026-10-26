// The switches on the mod's own pages (Mod Settings and every page under it) take iOS 26's switch below iOS 26 with the
// legacy glass: a wider track, and a white thumb that turns into glass under a finger (Core/SGGlassThumb.h). A switch counts when a
// controller of the mod's (SGPage, or any class of the SG prefix) holds it, and under the redesign also when it is one of Spotify's
// settings: a row's (id=PreferenceRowSwitch.Switch, in Settings_PlatformImpl's StandardSwitchElement, trees/continuous/5.txt) or the
// Equalizer's (in SPTEqualizerSwitchTableViewCell, 4.txt). Spotify's other switches are left as Spotify draws them. With the legacy
// glass off none of this runs, and every switch is UIKit's.
// The sliders there take iOS 26's thumb the same way, the one Speed, Pitch & Reverb's have (SpeedPitchMenu.x): a white
// capsule that swells into glass under a finger.
#import "Core/SGCore.h"
#import "SGPage.h"
#import <objc/runtime.h>

static BOOL onModPage(UIView *view) {
    for (UIResponder *r = view.nextResponder; r; r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        if ([r isKindOfClass:SGPage.class] || [NSStringFromClass(r.class) hasPrefix:@"SG"]) return YES;
    }
    return NO;
}

// One of Spotify's settings switches, which the redesign draws as the mod's own pages do.
static BOOL spotifySetting(UISwitch *toggle) {
    if (!SGRedesignedUI()) return NO;
    if ([toggle.accessibilityIdentifier isEqualToString:@"PreferenceRowSwitch.Switch"]) return YES;
    static Class equalizerCell;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ equalizerCell = NSClassFromString(@"SPTEqualizerSwitchTableViewCell"); });
    for (UIView *v = toggle.superview; v && equalizerCell; v = v.superview) {
        if ([v isKindOfClass:equalizerCell]) return YES;
        if ([v isKindOfClass:UITableView.class]) break;
    }
    return NO;
}

// Asked from every layout of every switch in the app: one that has its face already is not looked at again.
static char kAttachedKey;

static void attachIfOurs(UISwitch *toggle) {
    if (!toggle.window || objc_getAssociatedObject(toggle, &kAttachedKey)) return;
    if (!onModPage(toggle) && !spotifySetting(toggle)) return;
    SGGlassSwitchAttach(toggle);
    objc_setAssociatedObject(toggle, &kAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Speed, Pitch & Reverb's thumb (SpeedPitchMenu.x).
static const CGSize kSliderThumb = {34, 22};
static char kModSliderKey;

%hook UISlider
- (void)didMoveToWindow {
    %orig;
    UISlider *slider = (UISlider *)self;
    if (!slider.window || objc_getAssociatedObject(slider, &kModSliderKey)) return;
    if (!onModPage(slider)) return;
    objc_setAssociatedObject(slider, &kModSliderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGGlassThumbAttach(slider, kSliderThumb);
}

- (void)layoutSubviews {
    %orig;
    // Again on the owner's passes: a thumb image set again by the page is swapped back (SGGlassThumb.h).
    UISlider *slider = (UISlider *)self;
    if (objc_getAssociatedObject(slider, &kModSliderKey)) SGGlassThumbAttach(slider, kSliderThumb);
}
%end

// Spotify's settings rows name their switch (PreferenceRowSwitch.Switch) after it is in the window, and lay it out no more
// after that: asked only as it came in and on its layouts, a row's switch was never taken. So it is asked again as it is
// named, as it is set, and a turn after it comes in. A switch attached already returns at once.
%hook UISwitch
- (void)didMoveToWindow {
    %orig;
    UISwitch *toggle = (UISwitch *)self;
    attachIfOurs(toggle);
    __weak UISwitch *weakToggle = toggle;
    dispatch_async(dispatch_get_main_queue(), ^{ attachIfOurs(weakToggle); });
}

- (void)setAccessibilityIdentifier:(NSString *)identifier {
    %orig;
    attachIfOurs((UISwitch *)self);
}

- (void)layoutSubviews {
    %orig;
    attachIfOurs((UISwitch *)self);
    SGGlassSwitchSync((UISwitch *)self, NO);
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    %orig;
    attachIfOurs((UISwitch *)self);
    SGGlassSwitchSync((UISwitch *)self, animated);
}

- (void)setEnabled:(BOOL)enabled {
    %orig;
    SGGlassSwitchSync((UISwitch *)self, NO);
}
%end

%ctor {
    if (!SGUseLegacyGlass()) return;
    %init;
}
