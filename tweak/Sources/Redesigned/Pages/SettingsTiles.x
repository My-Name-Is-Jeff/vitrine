// Settings redesign: the three tiles at the top of Spotify's settings (Data saver mode, Offline mode, Private session)
// on glass. Each is an Encore Box that draws its gray as a shape layer the size of the box, the one gray block left on
// the page. Here that fill goes and the tile stands on a glass pane with rounded corners; the press highlight beside
// it (a shape inset by 4 at opacity 0) stays.
//
// Tree: QuickAccessSettingsRowElement > UIStackView of three MultipleChoiceQuickAccessSettingsElements, each
// holding Encore.Box id=QuickSettingsButton 124.5x71 with sublayers [CAShapeLayer 124.5x71; CAShapeLayer op=0 inset
// 4].
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kTileGlassKey;
static const CGFloat kTileRadius = 12;

static void dressTile(UIView *box) {
    if (![box.accessibilityIdentifier isEqualToString:@"QuickSettingsButton"] || !box.window || box.bounds.size.width < 1) return;
    CGRect bounds = box.layer.bounds;
    for (CALayer *layer in box.layer.sublayers) {
        if (![layer isKindOfClass:CAShapeLayer.class] || !CGRectEqualToRect(layer.frame, bounds)) continue;
        CAShapeLayer *fill = (CAShapeLayer *)layer;
        if (fill.fillColor && CGColorGetAlpha(fill.fillColor) > 0) fill.fillColor = UIColor.clearColor.CGColor;
    }
    SGRGlassPaneIn(box, &kTileGlassKey, kTileRadius);
}

%ctor {
    if (!SGRedesignedUI()) return;
    Class box = NSClassFromString(@"_TtCE16Encore_LayoutKitO16EncoreFoundation6Encore3Box");
    if (box) SGRPassView(box, ^(UIView *v) { dressTile(v); });
    else SGLog(@"class Encore.Box not found, the settings tiles stay gray");
}
