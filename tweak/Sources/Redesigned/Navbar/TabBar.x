// Tab bar: Spotify's own bar stays where it is but goes invisible, and a system UITabBar sits on top
// of it. On iOS 26+ with UIDesignRequiresCompatibility off, UIKit draws that bar as real Liquid Glass
// (selection bubble, lensing, light/dark adaptation) with no glass API of ours. Spotify's bar keeps
// its frame, so the page insets and the now playing bar stay where Spotify puts them; where the system
// bar is taller than Spotify's, Spotify is made to leave it the room (see "room for the glass bar").
//
// A tab picked on the system bar is passed on as a tap on the hidden Spotify item it mirrors, and the
// system bar's selection follows whichever Spotify label is painted white, or the tab of the mod's own whose
// page is up (SGRNavbarLitTab), which Spotify does not know of. Navbar.x composes the
// hidden row, so its order, hidden tabs and tabs of the mod's own carry over. Always on in the redesign.
//
// Tree (trees/home.txt): NavigationUI_TabBarImpl.TabBarView > TabBarCompactView > UIStackView of
//   ElementContentView<TabBarItemElement>, each with an SPTEncoreIconView and an SPTEncoreLabel.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "Redesigned/Kit/SGRTokens.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Settings/SGPage.h"
#import "Headers/SPTEncoreIconView.h"
#import "Shared/Navigation/TabIcons.h"
#import <objc/message.h>

static char kBarKey, kApartBarKey, kHostKey, kFadeKey;
static __weak UIView *sg_stockBar;
static __weak UIView *sg_customLitTab;
static CGFloat sg_room, sg_glassHeight;   // see "room for the glass bar"
// See "minimized". sg_keepApart holds the second bar on screen while the main one grows back under it.
static BOOL sg_minimized, sg_keepApart;

@interface SGRSystemTabBar : UITabBar <UITabBarDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *stockBar;
@property (nonatomic, copy) NSArray<UIView *> *sources;
@property (nonatomic, weak) UILongPressGestureRecognizer *hold;
@property (nonatomic) BOOL holding;
// The other bar, when the split tabs have one of their own: a tab picked on one bar clears the other's.
@property (nonatomic, weak) SGRSystemTabBar *partner;
// The item last shown selected, so a tap on it can be told from a tap that changes the tab.
@property (nonatomic, weak) UITabBarItem *shown;
@end

static void syncBar(UIView *stockBar);

#pragma mark - reading Spotify's items

// The items the bar shows, left to right as Navbar/Navbar.x placed them.
static NSArray<UIView *> *tabItems(UIView *tabBar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    for (UIView *item in SGRowIn(tabBar).arrangedSubviews) {
        if (!item.hidden && item.bounds.size.width >= 20) [items addObject:item];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(SGFrameIn(a, tabBar).origin.x) compare:@(SGFrameIn(b, tabBar).origin.x)];
    }];
}

// Navbar.x never reorders Spotify's row and appends the mod's own tabs after it, so Home stays first.
static BOOL isHome(UIView *item, UIView *tabBar) {
    return item && item == SGRowIn(tabBar).arrangedSubviews.firstObject;
}

static UILabel *labelIn(UIView *item) {
    __block UILabel *label = nil;
    SGForEachView(item, ^(UIView *v) {
        if (!label && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) label = (UILabel *)v;
    });
    return label;
}

static UIView *iconIn(UIView *item) {
    __block UIView *icon = nil;
    SGForEachView(item, ^(UIView *v) {
        if (icon || v.bounds.size.width < 2) return;
        if ([v isKindOfClass:UIImageView.class] || [NSStringFromClass(v.class) containsString:@"IconView"]) icon = v;
    });
    return icon;
}

// Spotify paints the selected tab's label white and the rest #B3B3B3.
static BOOL isActive(UIView *item) {
    UIColor *color = labelIn(item).textColor;
    CGFloat white = 0, alpha = 0, r, g, b;
    if (![color getWhite:&white alpha:&alpha] && [color getRed:&r green:&g blue:&b alpha:&alpha]) white = MIN(r, MIN(g, b));
    return white > 0.95;
}

static BOOL hasInk(UIImage *image) {
    CGImageRef cg = image.CGImage;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    if (!width || !height) return NO;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height];
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
    CGContextRelease(context);
    const uint8_t *alpha = pixels.bytes;
    for (size_t i = 0; i < pixels.length; i++) if (alpha[i] > 16) return YES;
    return NO;
}

static UIImage *renderLayer(CALayer *layer, CGSize size) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [layer renderInContext:context.CGContext];
    }];
    return hasInk(image) ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

// The SPTEncoreIcon an icon view was built with. Encore keeps it in a Swift ivar with no getter.
static id encoreIconOf(UIView *view) {
    Ivar ivar = class_getInstanceVariable(view.class, "icon");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(view, ivar) : nil;
}

// Encore draws a tab's icon from one SPTEncoreIcon in two states: isActive picks its filled variant.
// Both are drawn on an icon view of our own, off screen, so the images do not wait for Spotify's
// views to lay out and paint, and UITabBar swaps image and selectedImage itself.
static UIImage *glyphOf(UIView *item, BOOL active) {
    UIView *live = iconIn(item);
    if (!live) return nil;
    CGSize size = live.bounds.size;

    // 1. Manejo explícito para pestañas personalizadas / SF Symbols de la Mod
    if ([NSStringFromClass(item.class) isEqualToString:@"SGRTabItemView"] || [NSStringFromClass(live.class) containsString:@"UIImageView"]) {
        NSString *title = labelIn(item).text;
        if ([title containsString:@"Liked"] || [title containsString:@"Gusta"]) {
            UIImage *symbol = [UIImage systemImageNamed:active ? @"heart.fill" : @"heart"];
            if (symbol) return [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    }

    // 2. Manejo de variantes de la fuente vector de Spotify Encore
    id icon = encoreIconOf(live);
    Class viewClass = NSClassFromString(@"SPTEncoreIconView");
    if (icon && viewClass) {
        static NSCache<NSString *, UIImage *> *cache;
        if (!cache) cache = [NSCache new];
        NSString *key = [NSString stringWithFormat:@"%@ %d %@", [icon respondsToSelector:@selector(name)] ? [icon name] : icon, active, NSStringFromCGSize(size)];
        UIImage *cached = [cache objectForKey:key];
        if (cached) return cached;

        SPTEncoreIconView *view = [[viewClass alloc] initWithIcon:icon];
        view.frame = (CGRect){CGPointZero, size};
        [view setForegroundColor:UIColor.whiteColor];
        if ([view respondsToSelector:@selector(setActiveForegroundColor:)]) [view setActiveForegroundColor:UIColor.whiteColor];
        if ([view respondsToSelector:@selector(setIsActive:)]) [view setIsActive:active];
        [view layoutIfNeeded];

        UIImage *image = renderLayer(view.layer, size);
        if (image) {
            [cache setObject:image forKey:key];
            return image;
        }
    }
    
    return size.width >= 2 ? renderLayer(live.layer, size) : nil;
}

// For the Tab bar page's list and preview: a tab of Spotify's drawn from its item on the bar, hidden or not,
// found by the label its entry is named after; a tab of the mod's own drawn from its entry, as Navbar.x
// draws it on the bar. Nil while Spotify's item has not been built.
UIImage *SGRNavbarGlyph(NSDictionary *entry, BOOL active) {
    if (entry[SGRNavbarURI]) {
        UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
        UIView *icon = SGTabIconView(entry[SGRNavbarIcon], [entry[SGRNavbarIconSet] isEqual:SGTabIconSetSymbols], UIColor.whiteColor);
        icon.translatesAutoresizingMaskIntoConstraints = YES;
        icon.frame = holder.bounds;
        if ([icon isKindOfClass:UIImageView.class]) icon.contentMode = UIViewContentModeScaleAspectFit;
        [holder addSubview:icon];
        [holder layoutIfNeeded];
        return glyphOf(holder, active);
    }
    for (UIView *item in SGRowIn(sg_stockBar).arrangedSubviews) {
        if ([NSStringFromClass(item.class) isEqualToString:@"SGRTabItemView"]) continue;
        if ([labelIn(item).text isEqualToString:entry[SGRNavbarID]]) return glyphOf(item, active);
    }
    return nil;
}

#pragma mark - passing a tap on

// NavigationUI_TabBarImpl's TabBarItemElementUI answers a tap recognizer (-handleTap), so the tap is
// replayed through the recognizer's own target-action pairs, the same call a real touch ends in.
static BOOL fireTapRecognizers(UIView *view) {
    Ivar targetsIvar = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
    if (!targetsIvar) return NO;
    BOOL fired = NO;
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if (![recognizer isKindOfClass:UITapGestureRecognizer.class] || !recognizer.enabled) continue;
        for (id pair in object_getIvar(recognizer, targetsIvar)) {
            Ivar targetIvar = class_getInstanceVariable([pair class], "_target");
            Ivar actionIvar = class_getInstanceVariable([pair class], "_action");
            if (!targetIvar || !actionIvar) continue;
            id target = object_getIvar(pair, targetIvar);
            SEL action = *(SEL *)((char *)(__bridge void *)pair + ivar_getOffset(actionIvar));
            if (!target || !action || ![target respondsToSelector:action]) continue;
            SGLog(@"tab bar: tap -> %@ %@", NSStringFromClass([target class]), NSStringFromSelector(action));
            ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer);
            fired = YES;
        }
    }
    return fired;
}

static void forwardTap(UIView *item) {
    __block BOOL sent = NO;
    SGForEachView(item, ^(UIView *v) {
        if (!sent) sent = fireTapRecognizers(v);
    });
    SGForEachView(item, ^(UIView *v) {
        if (sent || ![v isKindOfClass:UIControl.class]) return;
        SGLog(@"tab bar: tap -> control %@", NSStringFromClass(v.class));
        [(UIControl *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        sent = YES;
    });
    if (!sent) {
        NSMutableString *out = [NSMutableString stringWithFormat:@"tab bar: nothing to tap in %@", NSStringFromClass(item.class)];
        SGForEachView(item, ^(UIView *v) {
            for (UIGestureRecognizer *r in v.gestureRecognizers) [out appendFormat:@"\n  %@ on %@", r, NSStringFromClass(v.class)];
        });
        SGLogLong(@"navbar", out);
    }
}

#pragma mark - the system bar

void SGRShrinkTabTitles(UIView *bar) {
    SGForEachView(bar, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class] || ((UILabel *)v).adjustsFontSizeToFitWidth) return;
        ((UILabel *)v).adjustsFontSizeToFitWidth = YES;
        ((UILabel *)v).minimumScaleFactor = 0.8;
    });
}

@implementation SGRSystemTabBar

- (void)layoutSubviews {
    [super layoutSubviews];
    SGRShrinkTabTitles(self);
}

- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSUInteger index = [self.items indexOfObject:item];
    if (index == NSNotFound || index >= self.sources.count) return;
    BOOL again = item == self.shown;
    self.shown = item;

    BOOL leading = self.stockBar && objc_getAssociatedObject(self.stockBar, &kBarKey) == self;
    if (sg_minimized && (again || leading)) {
        SGRSetTabBarMinimized(NO, YES);
        return;
    }

    UIView *source = self.sources[index];
    if (![NSStringFromClass(source.class) isEqualToString:@"SGRTabItemView"]) {
        sg_customLitTab = nil;
        SGRNavbarForgetTab();
        if (!self.holding) forwardTap(source);
    } else {
        // 1. Registra la pestaña personalizada localmente
        sg_customLitTab = source;
        
        // 2. Redirección para pestañas agregadas por el mod o con URIs de Spotify
        NSString *uri = objc_getAssociatedObject(source, "SGRTabURIKey") ?: @"spotify:user:me:collection";
        if ([uri isEqualToString:@"spotify:collection:tracks"]) {
            uri = @"spotify:user:me:collection";
        }
        
        NSURL *url = [NSURL URLWithString:uri];
        id router = [NSClassFromString(@"SPTDefaultLinkRouter") performSelector:@selector(sharedRouter)] ?:
                    [UIApplication.sharedApplication performSelector:@selector(delegate)];
        
        if ([router respondsToSelector:@selector(openURL:)]) {
            [router performSelector:@selector(openURL:) withObject:url];
        } else if ([UIApplication.sharedApplication canOpenURL:url]) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }
    }

    self.partner.selectedItem = nil;
    self.partner.shown = nil;

    UIView *stockBar = self.stockBar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (stockBar) syncBar(stockBar);
    });
}

- (UITabBarItem *)itemAt:(CGPoint)point {
    __block UITabBarItem *nearest = nil;
    __block CGFloat best = CGFLOAT_MAX;
    SGForEachView(self, ^(UIView *v) {
        BOOL label = [v isKindOfClass:UILabel.class], glyph = [v isKindOfClass:UIImageView.class];
        if ((!label && !glyph) || v.bounds.size.width < 1) return;
        CGFloat distance = fabs([v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), 0) toView:self].x - point.x);
        if (distance >= best) return;
        for (UITabBarItem *item in self.items) {
            UIImage *image = glyph ? ((UIImageView *)v).image : nil;
            if (label ? ![((UILabel *)v).text isEqualToString:item.title] : !image || (image != item.image && image != item.selectedImage)) continue;
            best = distance;
            nearest = item;
            break;
        }
    });
    return nearest;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != self.hold) return [super gestureRecognizerShouldBegin:recognizer];
    NSUInteger index = [self.items indexOfObject:[self itemAt:[recognizer locationInView:self]]];
    return index < self.sources.count && isHome(self.sources[index], self.stockBar);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)held:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        self.holding = YES;
        SGOpenModSettings(self);
    } else if (hold.state != UIGestureRecognizerStateChanged) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakSelf.holding = NO;
        });
    }
}

@end

@interface SGRTabBarHost : UIView
@end

@implementation SGRTabBarHost
- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = [super safeAreaInsets];
    insets.bottom = MAX(0, insets.bottom - sg_room);
    return insets;
}
@end

@interface SGRHomeHold : UILongPressGestureRecognizer
@end

@implementation SGRHomeHold
+ (void)held:(SGRHomeHold *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) SGOpenModSettings(hold.view);
}
@end

static void holdHome(UIView *stockBar) {
    UIView *home = SGRowIn(stockBar).arrangedSubviews.firstObject;
    if (!home) return;
    for (UIGestureRecognizer *recognizer in home.gestureRecognizers) {
        if ([recognizer isKindOfClass:SGRHomeHold.class]) return;
    }
    [home addGestureRecognizer:[[SGRHomeHold alloc] initWithTarget:SGRHomeHold.class action:@selector(held:)]];
}

static void logBarOnce(UITabBar *bar) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGLogLong(@"navbar", [NSString stringWithFormat:@"system tab bar %@\n%@", NSStringFromCGRect(bar.superview.frame), [bar recursiveDescription]]);
        });
    });
}

#pragma mark - the fade under the bars

@interface SGRBarFade : UIView
@end

@implementation SGRBarFade
+ (Class)layerClass {
    return CAGradientLayer.class;
}
@end

static const CGFloat kFadeAbove = 88;

static void placeFade(UIView *stockBar, CGRect glass) {
    SGRBarFade *fade = objc_getAssociatedObject(stockBar, &kFadeKey);
    if (!fade) {
        fade = [SGRBarFade new];
        fade.userInteractionEnabled = NO;
        CAGradientLayer *layer = (CAGradientLayer *)fade.layer;
        layer.colors = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:0.3].CGColor,
                         (id)[UIColor colorWithWhite:0 alpha:0.5].CGColor];
        layer.locations = @[@0, @0.5, @1];
        objc_setAssociatedObject(stockBar, &kFadeKey, fade, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat top = CGRectGetMinY(glass) - kFadeAbove;
    CGRect frame = CGRectMake(0, top, stockBar.bounds.size.width, CGRectGetMaxY(glass) - top);
    if (!CGRectEqualToRect(fade.frame, frame)) fade.frame = frame;
    if (fade.superview != stockBar || stockBar.subviews.firstObject != fade) [stockBar insertSubview:fade atIndex:0];
}

#pragma mark - room for the glass bar

static const CGFloat kStockRow = 49;

static CGFloat glassHeight(UITabBar *bar, UIView *stockBar) {
    if (sg_room < 0.5 || sg_glassHeight <= 0) sg_glassHeight = [bar sizeThatFits:CGSizeMake(stockBar.bounds.size.width, kStockRow)].height;
    return sg_glassHeight;
}

static UIViewController *containerOf(UIView *stockBar) {
    Class containerClass = NSClassFromString(@"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl");
    for (UIResponder *r = stockBar.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:containerClass]) return (UIViewController *)r;
    }
    return nil;
}

static void makeRoom(UIViewController *container) {
    UIView *stockBar = sg_stockBar;
    UITabBar *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    if (!bar.window || !container.isViewLoaded || ![stockBar isDescendantOfView:container.view]) return;
    UIEdgeInsets extra = container.additionalSafeAreaInsets;
    CGFloat inset = container.view.safeAreaInsets.bottom - extra.bottom;
    CGFloat height = glassHeight(bar, stockBar);
    BOOL compact = container.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    CGFloat room = compact ? MAX(0, ceil(height - kStockRow - inset)) : 0;
    if (fabs(extra.bottom - room) < 0.5) return;
    sg_room = extra.bottom = room;
    container.additionalSafeAreaInsets = extra;
    SGLog(@"tab bar: %.0f pt of room made under Spotify's bar for the glass bar's %.0f, over an inset of %.0f", room, height, inset);
}

static SGRSystemTabBar *makeBar(UIView *stockBar) {
    SGRSystemTabBar *bar = [[SGRSystemTabBar alloc] initWithFrame:stockBar.bounds];
    bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.delegate = bar;
    bar.stockBar = stockBar;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:bar action:@selector(held:)];
    hold.delegate = bar;
    [bar addGestureRecognizer:hold];
    bar.hold = hold;
    return bar;
}

static BOOL fillBar(SGRSystemTabBar *bar, NSArray<UIView *> *sources, BOOL hideLabels) {
    bar.tintColor = SGRAccent();
    if (![sources isEqualToArray:bar.sources]) {
        NSMutableArray<UITabBarItem *> *items = [NSMutableArray array];
        for (UIView *source in sources) [items addObject:[[UITabBarItem alloc] initWithTitle:hideLabels ? nil : labelIn(source).text image:nil tag:items.count]];
        bar.sources = sources;
        [bar setItems:items animated:NO];
        NSMutableString *out = [NSMutableString stringWithString:@"tab bar icons"];
        for (UIView *source in sources) {
            UIView *live = iconIn(source);
            id icon = live ? encoreIconOf(live) : nil;
            id variant = [icon respondsToSelector:NSSelectorFromString(@"active")] ? ((id (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"active")) : nil;
            [out appendFormat:@"\n  %@: %@ icon %@ active-variant %@ live-isActive %d label-white %d", labelIn(source).text, NSStringFromClass(live.class),
                 [icon respondsToSelector:@selector(name)] ? [icon name] : icon, [variant respondsToSelector:@selector(name)] ? [variant name] : variant,
                 [live respondsToSelector:@selector(isActive)] ? [(SPTEncoreIconView *)live isActive] : -1, isActive(source)];
        }
        SGLogLong(@"navbar", out);
    }

    BOOL missing = NO;
    for (NSUInteger i = 0; i < sources.count; i++) {
        UITabBarItem *item = bar.items[i];
        if (!item.image) item.image = glyphOf(sources[i], NO);
        if (!item.selectedImage || item.selectedImage == item.image) item.selectedImage = glyphOf(sources[i], YES);
        missing |= !item.image || !item.selectedImage;
        item.accessibilityLabel = labelIn(sources[i]).text;
        item.largeContentSizeImage = item.image;
        item.accessibilityHint = sg_minimized && bar == objc_getAssociatedObject(bar.stockBar, &kBarKey) ? @"Shows all tabs" : nil;
        NSString *title = hideLabels ? nil : labelIn(sources[i]).text;
        if (hideLabels ? item.title != nil : title.length && ![title isEqualToString:item.title]) item.title = title;
    }
    return missing;
}

static void selectActive(SGRSystemTabBar *bar, UIView *active) {
    NSUInteger index = active ? [bar.sources indexOfObject:active] : NSNotFound;
    UITabBarItem *item = index == NSNotFound ? nil : bar.items[index];
    if (active && bar.selectedItem != item) bar.selectedItem = item;
    if (active && item) bar.shown = item;
}

static UIView *selectedSource(SGRSystemTabBar *bar) {
    NSUInteger index = bar.selectedItem ? [bar.items indexOfObject:bar.selectedItem] : NSNotFound;
    return index < bar.sources.count ? bar.sources[index] : nil;
}

static const CGFloat kPlatterInset = 21, kApartItemWidth = 62, kPlatterGap = 12;

static void syncBar(UIView *stockBar) {
    sg_stockBar = stockBar;

    SGRSystemTabBar *bar = objc_getAssociatedObject(stockBar, &kBarKey);
    if (!bar) {
        bar = makeBar(stockBar);
        objc_setAssociatedObject(stockBar, &kBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRTabBarHost *host = [SGRTabBarHost new];
        [host addSubview:bar];
        objc_setAssociatedObject(stockBar, &kHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);

    for (UIView *sub in stockBar.subviews) {
        if (sub == host || [sub isKindOfClass:SGRBarFade.class]) continue;
        sub.alpha = 0;
        sub.userInteractionEnabled = NO;
    }
    stockBar.superview.layer.backgroundColor = NULL;

    NSArray<UIView *> *sources = tabItems(stockBar);
    if (!sources.count) return;

    BOOL hideLabels = SGHidden(SGRKeyNavbarHideLabels);
    SGRSystemTabBar *apartBar = objc_getAssociatedObject(stockBar, &kApartBarKey);
    UIView *active = sg_customLitTab ?: SGRNavbarLitTab();
    if (![sources containsObject:active]) active = nil;
    for (UIView *source in sources) if (!active && isActive(source)) active = source;
    active = active ?: selectedSource(bar) ?: selectedSource(apartBar);

    NSMutableArray<UIView *> *main = [NSMutableArray array], *apart = [NSMutableArray array];
    for (UIView *source in sources) [(SGRTabIsApart(source) ? apart : main) addObject:source];
    if (!main.count) {
        main = [sources mutableCopy];
        [apart removeAllObjects];
    }

    BOOL minimized = sg_minimized && sources.count >= 2;
    if (minimized) {
        UIView *last = apart.lastObject;
        main = [NSMutableArray arrayWithObject:active && active != last ? active : main.firstObject];
        apart = last ? [NSMutableArray arrayWithObject:last] : [NSMutableArray array];
        hideLabels = YES;
    }
    if (apart.count && !apartBar) {
        apartBar = makeBar(stockBar);
        objc_setAssociatedObject(stockBar, &kApartBarKey, apartBar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        apartBar.partner = bar;
        bar.partner = apartBar;
        [host addSubview:apartBar];
    }
    apartBar.hidden = !apart.count && !sg_keepApart;
    if (apartBar.hidden) apartBar.sources = nil;

    CGRect bounds = stockBar.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = MAX(bounds.size.height, glassHeight(bar, stockBar));
    CGRect frame = CGRectMake(0, CGRectGetMaxY(bounds) - height, width, height);
    if (!CGRectEqualToRect(host.frame, frame)) host.frame = frame;
    placeFade(stockBar, frame);
    CGRect mainFrame = host.bounds, apartFrame = CGRectZero;
    if (minimized) {
        CGFloat side = kApartItemWidth + 2 * kPlatterInset;
        mainFrame.size.width = side;
        if (apart.count) apartFrame = CGRectMake(width - side, 0, side, height);
    } else if (apart.count) {
        CGFloat apartWidth = MIN(width / 2, apart.count * kApartItemWidth + 2 * kPlatterInset);
        CGRectDivide(host.bounds, &apartFrame, &mainFrame, apartWidth, CGRectMaxXEdge);
        mainFrame.size.width += 2 * kPlatterInset - kPlatterGap;
    }
    if (!CGRectEqualToRect(bar.frame, mainFrame)) bar.frame = mainFrame;
    if (apart.count && !CGRectEqualToRect(apartBar.frame, apartFrame)) apartBar.frame = apartFrame;

    [host layoutIfNeeded];
    BOOL missing = fillBar(bar, main, hideLabels);
    if (apart.count) missing |= fillBar(apartBar, apart, hideLabels);
    selectActive(bar, active);
    if (apart.count) selectActive(apartBar, active);

    static NSUInteger retries;
    if (missing && retries++ < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            syncBar(stockBar);
        });
    }
    if (host.superview != stockBar) [stockBar addSubview:host];
    else if (stockBar.subviews.lastObject != host) [stockBar bringSubviewToFront:host];
    logBarOnce(bar);
    makeRoom(containerOf(stockBar));
}

#pragma mark - minimized

BOOL SGRTabBarMinimized(void) {
    return sg_minimized;
}

static void setMinimized(BOOL minimized, BOOL animated);

static NSUInteger sg_request;

void SGRSetTabBarMinimized(BOOL minimized, BOOL animated) {
    NSUInteger request = ++sg_request;
    if (!animated) {
        [UIView performWithoutAnimation:^{ setMinimized(minimized, NO); }];
        return;
    }
    if (UIView.areAnimationsEnabled && UIView.inheritedAnimationDuration <= 0) {
        setMinimized(minimized, YES);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (request == sg_request) setMinimized(minimized, YES);
    });
}

#pragma mark - one move

typedef struct {
    NSMapTable<UIView *, NSArray<NSValue *> *> *frames;
    NSMutableDictionary<NSString *, NSValue *> *glyphs;
    NSMapTable<UIView *, UIView *> *buttons;
} SGRBarState;

static BOOL isLitCopy(UIView *view, UIView *host) {
    for (UIView *up = view.superview; up && up != host; up = up.superview) {
        if ([NSStringFromClass(up.class) containsString:@"SelectedContent"]) return YES;
    }
    return NO;
}

static BOOL isMoving(UIView *view) {
    for (NSString *key in view.layer.animationKeys) if ([key hasPrefix:@"position"] || [key hasPrefix:@"bounds"]) return YES;
    return NO;
}

static UIImageView *glyphView(UIView *button) {
    __block UIImageView *glyph = nil;
    SGForEachView(button, ^(UIView *v) {
        if (!glyph && [v isKindOfClass:UIImageView.class] && !v.hidden && ((UIImageView *)v).image) glyph = (UIImageView *)v;
    });
    return glyph;
}

static BOOL isTabButton(UIView *view) {
    return [view isKindOfClass:UIControl.class] && glyphView(view) != nil;
}

static NSString *buttonKey(UIView *button, UIView *host) {
    if (!isTabButton(button) || !((UIControl *)button).selected) return nil;
    return isLitCopy(button, host) ? @"lit" : @"plain";
}

static CGRect shownIn(UIView *view, UIView *host) {
    CALayer *layer = view.layer.presentationLayer ?: view.layer, *top = host.layer.presentationLayer ?: host.layer;
    return [layer convertRect:layer.bounds toLayer:top];
}

static SGRBarState barState(UIView *host) {
    SGRBarState state = {
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory],
        [NSMutableDictionary dictionary],
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory],
    };
    SGForEachView(host, ^(UIView *v) {
        CALayer *shownLayer = v.layer.presentationLayer;
        [state.frames setObject:@[[NSValue valueWithCGRect:v.frame], [NSValue valueWithCGRect:shownLayer ? shownLayer.frame : v.frame], @(isMoving(v))] forKey:v];
        if (!v.window || v == host || !isTabButton(v)) return;
        CGRect shown = shownIn(v, host), glyph = shownIn(glyphView(v), host);
        NSString *key = buttonKey(v, host);
        if (key) state.glyphs[key] = [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(glyph), CGRectGetMidY(glyph))];
        if (isLitCopy(v, host)) return;
        UIView *picture = [v snapshotViewAfterScreenUpdates:NO];
        if (picture) {
            picture.frame = shown;
            [state.buttons setObject:picture forKey:v];
        }
    });
    return state;
}

static void moveFrom(UIView *host, SGRBarState before, void (^along)(void), void (^completion)(BOOL)) {
    NSMutableArray<UIView *> *moved = [NSMutableArray array], *faded = [NSMutableArray array];
    NSMutableArray<NSValue *> *starts = [NSMutableArray array], *targets = [NSMutableArray array];
    NSMutableSet<NSString *> *taken = [NSMutableSet set];
    SGForEachView(host, ^(UIView *v) {
        if (v == host) return;
        NSArray<NSValue *> *old = [before.frames objectForKey:v];
        if (old) {
            BOOL stopped = [(NSNumber *)old[2] boolValue] && !isMoving(v);
            CGRect start = stopped ? old[1].CGRectValue : old[0].CGRectValue;
            if (!stopped && CGRectEqualToRect(start, v.frame)) return;
            [moved addObject:v];
            [starts addObject:[NSValue valueWithCGRect:start]];
            [targets addObject:[NSValue valueWithCGRect:v.frame]];
            return;
        }
        if (![before.frames objectForKey:v.superview] || [v isKindOfClass:UITabBar.class]) return;
        NSString *key = buttonKey(v, host);
        NSValue *was = key ? before.glyphs[key] : nil;
        if (was) {
            [moved addObject:v];
            [starts addObject:was];
            [targets addObject:[NSValue valueWithCGRect:v.frame]];
            [taken addObject:key];
        } else if (isTabButton(v) && v.alpha > 0.01) {
            [faded addObject:v];
        }
    });
    NSMutableArray<UIView *> *gone = [NSMutableArray array];
    for (UIView *button in before.buttons) {
        BOOL replaced = ((UIControl *)button).selected && [taken containsObject:@"plain"];
        if (!button.window && !replaced) [gone addObject:[before.buttons objectForKey:button]];
    }

    [UIView performWithoutAnimation:^{
        for (NSUInteger i = 0; i < moved.count; i++) {
            UIView *v = moved[i];
            if (strcmp(starts[i].objCType, @encode(CGPoint)) != 0) {
                v.frame = starts[i].CGRectValue;
                continue;
            }
            UIImageView *glyph = glyphView(v);
            CGPoint inButton = [v convertPoint:glyph.center fromView:glyph.superview], to = [host convertPoint:starts[i].CGPointValue toView:v.superview];
            v.center = CGPointMake(to.x - (inButton.x - CGRectGetMidX(v.bounds)), to.y - (inButton.y - CGRectGetMidY(v.bounds)));
        }
        for (UIView *v in faded) v.alpha = 0;
        for (UIView *picture in gone) [host addSubview:picture];
    }];
    SGRAnimate(SGRMotionBar, ^{
        for (NSUInteger i = 0; i < moved.count; i++) moved[i].frame = targets[i].CGRectValue;
        if (along) along();
    }, completion);
    SGRAnimate(SGRMotionExit, ^{ for (UIView *picture in gone) picture.alpha = 0; }, ^(BOOL finished) {
        for (UIView *picture in gone) [picture removeFromSuperview];
    });
    SGRAnimate(SGRMotionFade, ^{ for (UIView *v in faded) v.alpha = 1; }, nil);
}

static void setMinimized(BOOL minimized, BOOL animated) {
    UIView *stockBar = sg_stockBar;
    if (minimized == sg_minimized) return;
    if (minimized && (!stockBar.window || stockBar.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassCompact)) return;
    sg_minimized = minimized;
    sg_keepApart = !minimized;
    SGLog(@"tab bar: %@", minimized ? @"minimized" : @"expanded");
    if (!stockBar) return;
    UIView *host = objc_getAssociatedObject(stockBar, &kHostKey);
    void (^settle)(BOOL) = ^(BOOL finished) {
        if (sg_minimized != minimized) return;
        sg_keepApart = NO;
        syncBar(stockBar);
    };
    animated &= host.window != nil;
    SGRBarState before = animated ? barState(host) : (SGRBarState){0};

    [UIView performWithoutAnimation:^{
        syncBar(stockBar);
        [host layoutIfNeeded];
        if (!minimized) {
            ((SGRSystemTabBar *)objc_getAssociatedObject(stockBar, &kBarKey)).sources = nil;
            ((SGRSystemTabBar *)objc_getAssociatedObject(stockBar, &kApartBarKey)).sources = nil;
            syncBar(stockBar);
            [host layoutIfNeeded];
        }
        if (!animated) SGRNowPlayingBarFollowTabBar();
    }];
    if (!animated) {
        settle(YES);
        return;
    }
    moveFrom(host, before, ^{ SGRNowPlayingBarFollowTabBar(); }, settle);
}

CGRect SGRTabBarInlineSlot(UIView *host, CGFloat height) {
    UIView *stockBar = sg_stockBar;
    UIView *bar = stockBar ? objc_getAssociatedObject(stockBar, &kBarKey) : nil;
    UIView *apartBar = stockBar ? objc_getAssociatedObject(stockBar, &kApartBarKey) : nil;
    if (!sg_minimized || !host || !bar.window || stockBar.hidden || stockBar.alpha < 0.01) return CGRectNull;

    CGRect lead = [bar.superview convertRect:bar.frame toView:host];
    CGFloat left = CGRectGetMinX(lead) + kPlatterInset + kApartItemWidth + SGRGrid;
    CGFloat right;
    if (apartBar && !apartBar.hidden) {
        CGRect trail = [apartBar.superview convertRect:apartBar.frame toView:host];
        right = CGRectGetMaxX(trail) - kPlatterInset - kApartItemWidth - SGRGrid;
    } else {
        CGRect whole = [stockBar convertRect:stockBar.bounds toView:host];
        right = CGRectGetMaxX(whole) - kPlatterInset;
    }
    CGFloat middle = CGRectGetMinY(lead) + kApartItemWidth / 2;
    CGRect slot = CGRectMake(left, middle - height / 2, right - left, height);

    CGRect inWindow = [host convertRect:slot toView:nil];
    if (slot.size.width < 100 || CGRectGetMaxY(inWindow) > CGRectGetMaxY(bar.window.bounds)) return CGRectNull;
    return slot;
}

#pragma mark - hooks

static UIView *tabBarOf(UIView *item) {
    Class barClass = NSClassFromString(@"_TtC23NavigationUI_TabBarImpl10TabBarView");
    for (UIView *v = item.superview; v; v = v.superview) if ([v isKindOfClass:barClass]) return v;
    return nil;
}

%hook _TtC23NavigationUI_TabBarImpl10TabBarView
- (void)layoutSubviews {
    %orig;
    SGRComposeTabBar((UIView *)self);
    for (UIView *sub in ((UIView *)self).subviews) {
        if (![sub isKindOfClass:SGRTabBarHost.class] && ![sub isKindOfClass:SGRBarFade.class]) [sub layoutIfNeeded];
    }
    holdHome((UIView *)self);
    syncBar((UIView *)self);
    SGRLogTabBarRow((UIView *)self);
}
%end

static void itemDidLayOut(UIView *item) {
    UIView *bar = tabBarOf(item);
    if (!bar) return;
    SGRComposeTabBar(bar);
    holdHome(bar);
    syncBar(bar);
    SGRLogTabBarRow(bar);
}

%hook _TtC23NavigationUI_TabBarImpl21TabBarItemElementView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

%hook _TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView
- (void)layoutSubviews {
    %orig;
    itemDidLayOut((UIView *)self);
}
%end

%hook _TtC23NavigationUI_TabBarImpl19TabBarContainerImpl
- (void)setSelectedViewController:(UIViewController *)controller {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGRSetTabBarMinimized(NO, YES);
        UIView *bar = sg_stockBar;
        if (bar) syncBar(bar);
    });
}

- (void)viewSafeAreaInsetsDidChange {
    %orig;
    makeRoom((UIViewController *)self);
}
%end

// Spotify's own fade under its bar, 219 pt down to black from 9.1.90 (TabBarGradientView), stacked with SGRBarFade
// into a band near black over the page's foot. SGRBarFade is the redesign's, so Spotify's stays clear.
%group SpotifyBarFade
%hook _TtC23NavigationUI_TabBarImpl18TabBarGradientView
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).alpha = 0;
}
- (void)setAlpha:(CGFloat)alpha {
    %orig(0);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    if (objc_getClass("_TtC23NavigationUI_TabBarImpl18TabBarGradientView")) %init(SpotifyBarFade);
    SGRequireClasses(@[
        @"_TtC23NavigationUI_TabBarImpl10TabBarView",
        @"_TtC23NavigationUI_TabBarImpl21TabBarItemElementView",
        @"_TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView",
        @"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl",
    ]);
}
